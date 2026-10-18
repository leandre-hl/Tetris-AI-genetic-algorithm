(* genetic.ml - Genetic algorithm that searches the 20 weights of the Tetris
   bot (see tetris.ml).

   Overview
   --------
   An individual ("candidate") is a vector of weights (its genotype) together
   with one mutation step size (sigma) per weight, so the mutation strength is
   itself inherited and evolves, as in an evolution strategy. Its fitness is
   the mean number of lines cleared over several random games.

   Each generation:
   1. all candidates are evaluated in parallel (one OCaml domain per core);
   2. the [n_elite] best are kept and saved to disk;
   3. a new population of [population_size] children is built from random
      pairs of elites: uniform crossover, then mutation, then normalisation.
      The elites themselves are NOT copied unchanged into the next population;
      only their children are evaluated. *)

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type parameters = {
  dir_save        : string;      (* directory where each generation is saved *)
  load            : int option;  (* Some n: resume from generation n of [dir_save];
                                    None: start from a random population *)
  population_size : int;         (* number of candidates evaluated per generation *)
  n_elite         : int;         (* number of best candidates kept as parents *)
  n_generations   : int;         (* last generation to compute *)
  init_sigma      : float;       (* initial sigma of every gene; also the standard
                                    deviation of the noise applied to sigma when
                                    sigma itself mutates *)
  dec_sigma       : float;       (* typical factor applied to sigma when it mutates
                                    (below 1: the search gets more precise) *)
  mutation_rate   : float;       (* probability, between 0 and 1, that a given
                                    gene (or sigma) mutates *)
  n_genes         : int;         (* number of weights, must match [Tetris.eval] *)
}

type candidate = {
  genotype : float array;  (* the weights of the evaluation function *)
  sigma    : float array;  (* mutation step size of each weight *)
  fitness  : float option; (* None until the candidate has been evaluated *)
}

type population = candidate list

(* ------------------------------------------------------------------------- *)
(* Fitness                                                                   *)
(* ------------------------------------------------------------------------- *)

(* Number of random games played to evaluate one candidate. More games give a
   less noisy fitness but a slower generation. *)
let games_per_evaluation = 100

(* Fitness of a genotype: mean number of lines cleared by the bot over
   [games_per_evaluation] games. *)
let fitness_function genotype =
  Tetris.mean_score genotype games_per_evaluation Tetris.eval

(* Fitness of a candidate, 0 if it has not been evaluated. *)
let fitness_value candidate =
  match candidate.fitness with
  | Some f -> f
  | None -> 0.

(* Ordering used to sort candidates from best to worst. Candidates without
   fitness come last. *)
let by_decreasing_fitness a b =
  match a.fitness, b.fitness with
  | Some fa, Some fb -> compare fb fa
  | Some _, None -> -1
  | None, Some _ -> 1
  | None, None -> 0

let mean_fitness population =
  let n = List.length population in
  List.fold_left (fun acc c -> acc +. fitness_value c) 0. population
  /. float_of_int n

(* Sample standard deviation (n - 1 in the denominator) of the fitness. *)
let fitness_std_dev population mean =
  let n = List.length population in
  if n < 2 then 0.
  else begin
    let sum_squares =
      List.fold_left
        (fun acc c -> acc +. (fitness_value c -. mean) ** 2.)
        0. population
    in
    sqrt (sum_squares /. float_of_int (n - 1))
  end

(* ------------------------------------------------------------------------- *)
(* Genetic operators                                                         *)
(* ------------------------------------------------------------------------- *)

(* Random number drawn from a normal distribution N(0, sigma), using the
   Box-Muller transform. [u1] lies in (0, 1] so that [log u1] is always
   finite. *)
let gaussian sigma =
  let u1 = 1.0 -. Random.float 1.0 in
  let u2 = Random.float 1.0 in
  sigma *. sqrt (-2.0 *. log u1) *. cos (2.0 *. Float.pi *. u2)

(* Divide the genotype by the sum of the absolute values of its weights.
   Only the relative weights matter to the bot (it compares costs), so this
   keeps the scale of the weights from drifting. *)
let normalise candidate =
  let sum_abs =
    Array.fold_left (fun acc w -> acc +. abs_float w) 0. candidate.genotype
  in
  { candidate with genotype = Array.map (fun w -> w /. sum_abs) candidate.genotype }

(* Random candidate: weights uniform in [-1, 1], all sigmas equal to
   [init_sigma]. *)
let random_candidate n_genes init_sigma =
  { genotype = Array.init n_genes (fun _ -> Random.float 2.0 -. 1.0);
    sigma = Array.make n_genes init_sigma;
    fitness = None }

(* Mutation. Each sigma and each weight mutates independently with probability
   [mutation_rate]:
   - a sigma is multiplied by max (dec_sigma + N(0, init_sigma), 0.8), i.e. by
     a random factor close to [dec_sigma], never below 0.8;
   - a weight w becomes w * N(1, sigma), a relative change of the weight,
     using the (possibly just mutated) sigma of that weight. A weight equal to
     0 therefore never moves. *)
let mutate candidate init_sigma dec_sigma mutation_rate =
  let should_mutate () = Random.float 1. <= mutation_rate in
  let sigma =
    Array.map
      (fun s ->
         if should_mutate () then s *. max (dec_sigma +. gaussian init_sigma) 0.8
         else s)
      candidate.sigma
  in
  let genotype =
    Array.mapi
      (fun i w ->
         if should_mutate () then w +. (gaussian sigma.(i)) *. w else w)
      candidate.genotype
  in
  { genotype; sigma; fitness = None }

(* Uniform crossover: every weight, and independently every sigma, is taken
   from one of the two parents with probability 1/2. *)
let crossover parent1 parent2 =
  let pick a b = if Random.bool () then a else b in
  let n = Array.length parent1.genotype in
  { genotype = Array.init n (fun i -> pick parent1.genotype.(i) parent2.genotype.(i));
    sigma = Array.init n (fun i -> pick parent1.sigma.(i) parent2.sigma.(i));
    fitness = None }

(* Keep the [n_elite] best candidates, best first. *)
let select_elite population n_elite =
  List.sort by_decreasing_fitness population
  |> List.filteri (fun i _ -> i < n_elite)

(* Build the next (unevaluated) population: [population_size] children, each
   made from two parents drawn at random among [parents] (possibly the same
   one twice), then mutated and normalised. *)
let new_population parents parameters =
  let parents = Array.of_list parents in
  let pick_parent () = parents.(Random.int (Array.length parents)) in
  List.init parameters.population_size (fun _ ->
      let child = crossover (pick_parent ()) (pick_parent ()) in
      normalise
        (mutate child parameters.init_sigma parameters.dec_sigma
           parameters.mutation_rate))

(* ------------------------------------------------------------------------- *)
(* Saving and loading                                                        *)
(* ------------------------------------------------------------------------- *)

(* File of generation [n] inside directory [dir]. *)
let generation_file dir n =
  Filename.concat dir (Printf.sprintf "population_gen_%d.txt" n)

(* Write "<label>: v1 v2 ... vn " followed by a newline. *)
let write_floats oc label values =
  Printf.fprintf oc "%s: " label;
  Array.iter (Printf.fprintf oc "%f ") values;
  output_char oc '\n'

(* Save a list of candidates, three lines each:
     Genotype: w1 w2 ...
     Sigma: s1 s2 ...
     Fitness: f   (or "None")  *)
let save_population filename population =
  let oc = open_out filename in
  List.iter
    (fun c ->
       write_floats oc "Genotype" c.genotype;
       write_floats oc "Sigma" c.sigma;
       Printf.fprintf oc "Fitness: %s\n"
         (match c.fitness with
          | Some f -> string_of_float f
          | None -> "None"))
    population;
  close_out oc

(* Append one "elite_mean,best" line to the CSV file [filename]. *)
let append_stats filename elite_mean best =
  let oc = open_out_gen [Open_append; Open_creat] 0o666 filename in
  Printf.fprintf oc "%s,%s\n" (string_of_float elite_mean) (string_of_float best);
  close_out oc

(* Remove [prefix] from the beginning of [line] and trim the rest. *)
let strip_prefix prefix line =
  if String.starts_with ~prefix line then
    String.trim
      (String.sub line (String.length prefix)
         (String.length line - String.length prefix))
  else
    failwith (Printf.sprintf "Invalid population file: expected a line starting with %S" prefix)

(* Parse "<prefix> v1 v2 ... vn" into a float array. *)
let parse_floats prefix line =
  strip_prefix prefix line
  |> String.split_on_char ' '
  |> List.filter (fun s -> s <> "")
  |> List.map float_of_string
  |> Array.of_list

(* Parse "Fitness: <float>" or "Fitness: None". *)
let parse_fitness line =
  match strip_prefix "Fitness:" line with
  | "None" -> None
  | value -> Some (float_of_string value)

(* Read a file written by [save_population]. Lines that are not part of a
   candidate (blank lines, for instance) are ignored. *)
let load_population filename =
  let ic = open_in filename in
  let rec read_candidates acc =
    match String.trim (input_line ic) with
    | exception End_of_file -> List.rev acc
    | line when String.starts_with ~prefix:"Genotype:" line ->
        let genotype = parse_floats "Genotype:" line in
        let sigma = parse_floats "Sigma:" (String.trim (input_line ic)) in
        let fitness = parse_fitness (String.trim (input_line ic)) in
        read_candidates ({ genotype; sigma; fitness } :: acc)
    | _ -> read_candidates acc
  in
  Fun.protect ~finally:(fun () -> close_in ic) (fun () -> read_candidates [])

(* ------------------------------------------------------------------------- *)
(* Display                                                                   *)
(* ------------------------------------------------------------------------- *)

(* Print every weight of [candidate] with its name and its sigma. *)
let print_best_candidate candidate =
  Array.iteri
    (fun i w ->
       Printf.printf "Param %02d (%s) : %f|%f\n" i Tetris.name_params.(i) w
         candidate.sigma.(i))
    candidate.genotype

(* Progress bar such as "[#####---------------] 05/20", redrawn on the same
   line. *)
let print_progress completed total =
  let bar_width = 20 in
  let filled = completed * bar_width / max total 1 in
  let bar = String.make filled '#' ^ String.make (bar_width - filled) '-' in
  Printf.printf "[%s] %02d/%02d%!" bar completed total

let print_generation_report ~generation ~best ~elite ~elite_mean ~record
    ~record_generation ~elapsed =
  Printf.printf "Generation %d:\n" generation;
  print_best_candidate best;
  Printf.printf "All-time record : %f (generation %d)\n" record record_generation;
  Printf.printf "Best score      : %f\n" (fitness_value best);
  Printf.printf "Elite mean      : %f\n" elite_mean;
  Printf.printf "Elite std dev   : %f\n" (fitness_std_dev elite elite_mean);
  let seconds = int_of_float elapsed in
  let now = Unix.localtime (Unix.time ()) in
  Printf.printf "Elapsed time    : %02d:%02d:%02d (clock time: %02d:%02d:%02d)\n\n%!"
    (seconds / 3600) (seconds / 60 mod 60) (seconds mod 60)
    now.Unix.tm_hour now.Unix.tm_min now.Unix.tm_sec

(* ------------------------------------------------------------------------- *)
(* Evaluation                                                                *)
(* ------------------------------------------------------------------------- *)

let evaluate_candidate candidate =
  { candidate with fitness = Some (fitness_function candidate.genotype) }

(* Evaluate a whole population in parallel on the domain pool [pool]. The
   returned list keeps the order of [population]. *)
let evaluate_population population =
  let candidates = Array.of_list population in
  let total = Array.length candidates in
  let results = Array.make total None in
  (* Shared between domains, hence atomic. *)
  let next = Atomic.make 0 in
  let completed = Atomic.make 0 in
  let worker () =
    let running = ref true in
    while !running do
      let i = Atomic.fetch_and_add next 1 in
      if i >= total then running := false
      else begin
        let evaluated = evaluate_candidate candidates.(i) in
        results.(i) <- Some evaluated;
        let done_count = Atomic.fetch_and_add completed 1 + 1 in
        Printf.printf "\rCandidate %02d got a mean score of %f\n%!" i
          (fitness_value evaluated);
        print_progress done_count total
      end
    done
  in
  Printf.printf "Evaluating %d candidates...\n%!" total;
  print_progress 0 total;
  let n_workers = max 1 (min total (Domain.recommended_domain_count ())) in
  let domains = List.init (n_workers - 1) (fun _ -> Domain.spawn worker) in
  worker ();
  List.iter Domain.join domains;
  print_newline ();
  results |> Array.to_list |> List.filter_map Fun.id


(* ------------------------------------------------------------------------- *)
(* Main loop                                                                 *)
(* ------------------------------------------------------------------------- *)

(* Run the genetic algorithm and return the best candidate of a final
   evaluation. Each generation's elite is saved in [parameters.dir_save]
   (which must already exist) and its statistics are appended to
   [dir_save/data.csv], so a long run can be stopped and resumed with
   [load = Some n]. *)
let genetic_algorithm parameters =
  (* Initial population: random, or the children of a saved elite. *)
  let population =
    ref (match parameters.load with
        | None ->
            List.init parameters.population_size (fun _ ->
                random_candidate parameters.n_genes parameters.init_sigma)
        | Some generation ->
            let file = generation_file parameters.dir_save generation in
            let elite = load_population file in
            Printf.printf "Loaded %d individuals from %s\n%!"
              (List.length elite) file;
            new_population elite parameters)
  in
  let first_generation =
    match parameters.load with None -> 1 | Some n -> n + 1
  in
  let record = ref 0. and record_generation = ref 0 in
 
  for generation = first_generation to parameters.n_generations do
    let start_time = Unix.gettimeofday () in
 
    (* Evaluate everybody and keep the best. *)
    let evaluated = evaluate_population !population in
    let elite = select_elite evaluated parameters.n_elite in
    let best = List.hd elite in
    let best_fitness = fitness_value best in
    let elite_mean = mean_fitness elite in
    if best_fitness > !record then begin
      record := best_fitness;
      record_generation := generation
    end;
 
    (* Save the elite and log the generation. *)
    save_population (generation_file parameters.dir_save generation) elite;
    append_stats (Filename.concat parameters.dir_save "data.csv")
      elite_mean best_fitness;
    print_generation_report ~generation ~best ~elite ~elite_mean
      ~record:!record ~record_generation:!record_generation
      ~elapsed:(Unix.gettimeofday () -. start_time);
 
    (* Children of the elite form the next population. *)
    population := new_population elite parameters
  done;
 
  (* Evaluate the last population and return its best individual. *)
  let final_population = evaluate_population !population in
  List.hd (List.sort by_decreasing_fitness final_population)