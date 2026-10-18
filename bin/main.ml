(* main.ml — Entry point: trains a Tetris bot with a genetic algorithm.

   The bot scores every possible placement of a piece with a weighted sum of
   20 board features. The genetic algorithm searches for the 20 weights
   (the "genes") that clear the most lines on average.

   Usage:  dune exec bin/main.exe
   Output: one file per generation in [save_dir] (the elite individuals),
           plus a [data.csv] file with the elite average and best fitness. *)

let parameters : Genetic.parameters =
  {
    (* Directory where generations are saved. It must be a single-level path
       (e.g. "runs"), because [Sys.mkdir] does not create parent directories. *)
    dir_save = "training_data";

    (* Resume a previous run?
       - None    : start from a random population
       - Some n  : reload the elite saved in generation n and continue from n+1 *)
    load = None;

    (* Number of candidates evaluated in each generation. *)
    population_size = 100;

    (* Number of best candidates kept as parents of the next generation. *)
    n_elite = 10;

    (* Upper bound on the number of generations. The value is deliberately
       huge: the run is meant to be stopped by hand (Ctrl+C), and every
       generation is saved so it can be resumed with [load]. *)
    n_generations = 100_000;

    (* Initial standard deviation of the mutation noise. Mutations are
       relative: a gene g becomes N(1, sigma) * g where N is the normal
       distribution. It must be adjusted by hand. *)
    init_sigma = 0.1;

    (* Multiplicative decay applied to sigma when it mutates
       (0.95 means about -5% per mutation on average), so the search
       gradually becomes more precise. *)
    dec_sigma = 0.95;

    (* Probability, between 0 and 1, that each gene is mutated
       (0.35 = 35% of the genes on average). *)
    mutation_rate = 0.35;

    (* Number of weights per individual. It must match the number of
       features used by [Tetris.eval]. *)
    n_genes = 20;
  }

let () =
  Random.self_init ();

  (* Create the output directory if it does not exist yet. *)
  let ensure_dir dir =
    if not (Sys.file_exists dir) then Sys.mkdir dir 0o755
  in 
  ensure_dir parameters.dir_save;

  (* Begin genetic algorithm *)
  let best = Genetic.genetic_algorithm parameters in

  (* Analyse results *)
  match best.fitness with
  | Some fitness ->
      Printf.printf "Best fitness: %f lines cleared on average\n" fitness;
      Genetic.print_best_candidate best
  | None ->
      print_endline "No fitness was computed."