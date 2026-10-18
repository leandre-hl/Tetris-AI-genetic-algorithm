(* tetris.ml - Tetris engine and greedy bot used as the fitness function of the
   genetic algorithm.

   Overview
   --------
   - The board is 10 columns wide and 16 rows high.
   - Pieces are dropped straight down: there is no sliding or late rotation.
     For each piece the bot looks at every (rotation, column) placement, scores
     the resulting board with [eval] and plays the placement with the LOWEST
     cost.
   - [eval] is a weighted sum of 20 board features. The 20 weights form the
     "individual" (genotype) optimised by genetic.ml.
   - [mean_score] plays 100 random games with a given set of weights and
     returns the average number of cleared lines: this is the fitness.

   Conventions
   -----------
   - x is the column, from 0 (left) to 9 (right).
   - y is the row, from 0 (floor) to 15 (top).
   - The board is stored as a bitset in a [Bytes.t]. The cell (x, y) is the bit
     number [x + 10 * y]. *)

(* ------------------------------------------------------------------------- *)
(* Configuration                                                             *)
(* ------------------------------------------------------------------------- *)

let board_width = 10
let board_height = 16

(* Number of bytes needed to store board_width * board_height bits. *)
let board_bytes = (board_width * board_height + 7) / 8

(* Display options, only used by [print_wall]. *)
let support_ANSI = true
let support_UNICODE = true

(* ------------------------------------------------------------------------- *)
(* Pieces                                                                    *)
(* ------------------------------------------------------------------------- *)

type position = { x : int; y : int }

(* A piece is the list of the 4 cells it covers, given as offsets from an
   anchor cell (0, 0). *)
type piece = { parts : position array }

(* Result of testing a piece position on the board:
   - Free      : every cell is inside the board and free
   - Out       : some cells are outside the board (e.g. above the top)
   - Forbidden : some cell is already occupied *)
type status = Free | Out | Forbidden

(* The 7 tetrominoes in their initial orientation. *)
let tetraminos =
  [| { parts = [| {x=0;y=0}; {x= -1;y=0}; {x=1;y=0}; {x=2;y=0} |] };       (* I *)
     { parts = [| {x=0;y=0}; {x=1;y=0}; {x=0;y= -1}; {x=1;y= -1} |] };     (* O *)
     { parts = [| {x=0;y=0}; {x=1;y=0}; {x=0;y=1}; {x=0;y= -1} |] };       (* T *)
     { parts = [| {x=0;y=0}; {x=1;y=0}; {x=1;y=1}; {x=0;y= -1} |] };       (* S *)
     { parts = [| {x=0;y=0}; {x=1;y=0}; {x=0;y=1}; {x=1;y= -1} |] };       (* Z *)
     { parts = [| {x=0;y=0}; {x=1;y= -1}; {x=0;y=1}; {x=0;y= -1} |] };     (* J *)
     { parts = [| {x=0;y=0}; {x= -1;y= -1}; {x=0;y=1}; {x=0;y= -1} |] } |] (* L *)

(* Number of distinct orientations of each piece (symmetric pieces have fewer
   than 4). *)
let num_rotations = [| 2; 1; 4; 2; 2; 4; 4 |]

(* Rotate a piece by 90 degrees clockwise around its anchor (0, 0). *)
let rotate piece =
  { parts = Array.map (fun c -> { x = c.y; y = - c.x }) piece.parts }

let rec rotate_n piece n =
  if n = 0 then piece else rotate_n (rotate piece) (n - 1)

(* pieces_rotations.(k).(d) is piece k rotated d times (0 <= d < num_rotations.(k)).
   Computed once at startup so that the search never has to rotate pieces. *)
let pieces_rotations =
  Array.mapi
    (fun k piece -> Array.init num_rotations.(k) (fun d -> rotate_n piece d))
    tetraminos

(* Range (xmin, xmax) of the anchor columns for which a piece fits horizontally
   inside the board. *)
let column_range piece =
  let xs = Array.map (fun c -> c.x) piece.parts in
  let min_dx = Array.fold_left min xs.(0) xs
  and max_dx = Array.fold_left max xs.(0) xs in
  (0 - min_dx, board_width - 1 - max_dx)

(* pieces_placement.(k).(d) = column_range of pieces_rotations.(k).(d). *)
let pieces_placement = Array.map (Array.map column_range) pieces_rotations

(* ------------------------------------------------------------------------- *)
(* Board representation (bitset)                                             *)
(* ------------------------------------------------------------------------- *)

(* Linear index of the cell (x, y). *)
let pos x y = x + board_width * y

let get_bit t idx =
  let byte = int_of_char (Bytes.get t (idx / 8)) in
  (byte lsr (idx mod 8)) land 1 = 1

let set_bit t idx value =
  let byte_index = idx / 8 in
  let byte = int_of_char (Bytes.get t byte_index) in
  let mask = 1 lsl (idx mod 8) in
  let new_byte = if value then byte lor mask else byte land (lnot mask) in
  Bytes.set t byte_index (char_of_int new_byte)

(* ------------------------------------------------------------------------- *)
(* Game mechanics                                                            *)
(* ------------------------------------------------------------------------- *)

(* Check whether [piece], anchored at (x, y), fits on the board [t]. *)
let test piece t x y =
  let out = ref false and collide = ref false and i = ref 0 in
  while not !collide && !i < 4 do
    let xi = x + piece.parts.(!i).x
    and yi = y + piece.parts.(!i).y in
    if xi < 0 || xi >= board_width || yi < 0 || yi >= board_height then
      out := true
    else if get_bit t (pos xi yi) then
      collide := true;
    incr i
  done;
  if !collide then Forbidden
  else if !out then Out
  else Free

(* Row where [piece] comes to rest when dropped straight down in column [x]:
   the lowest row reachable before hitting the stack. Returns -1 if the piece
   cannot be placed at all (game over). *)
let stop piece t x =
  let last_Free = ref (-1) in
  let y = ref (board_height - 1) in
  let status = ref Free in
  while !status <> Forbidden && !y >= 0 do
    status := test piece t x !y;
    if !status = Free then last_Free := !y;
    decr y
  done;
  !last_Free

(* Write [piece] into the board at (x, y). Returns its landing height, i.e. the
   row of its highest cell (computed before any line is cleared). *)
let place_piece piece t x y =
  let landing_height = ref 0 in
  Array.iter
    (fun c ->
       let cy = y + c.y in
       set_bit t (pos (x + c.x) cy) true;
       if cy > !landing_height then landing_height := cy)
    piece.parts;
  !landing_height

(* A row is full when all of its cells are occupied. *)
let full_line t y =
  let full = ref true and x = ref 0 in
  while !full && !x < board_width do
    if not (get_bit t (pos !x y)) then full := false;
    incr x
  done;
  !full

(* Remove every full row (rows above fall down) and return how many were
   removed. Works in place. *)
let clear_lines t =
  (* Compact the remaining rows towards the floor. [dest] is the next free row. *)
  let dest = ref 0 in
  for y = 0 to board_height - 1 do
    if not (full_line t y) then begin
      if !dest <> y then
        for x = 0 to board_width - 1 do
          set_bit t (pos x !dest) (get_bit t (pos x y))
        done;
      incr dest
    end
  done;
  (* Empty the rows freed at the top. *)
  for y = !dest to board_height - 1 do
    for x = 0 to board_width - 1 do
      set_bit t (pos x y) false
    done
  done;
  board_height - !dest

(* ------------------------------------------------------------------------- *)
(* Board features used by the evaluation function                            *)
(* ------------------------------------------------------------------------- *)

(* Heights array used by the evaluation function *)
let get_heights_array t =
  (* Height of column [x]: 1 + row of its highest occupied cell, 0 if empty. *)
  let col_height t x =
    let rec find y =
      if y < 0 || get_bit t (pos x y) then y + 1 else find (y - 1)
    in
    find (board_height - 1)
  in
  Array.init board_width (col_height t)

let height heights = Array.fold_left max 0 heights

let sum_height heights = Array.fold_left ( + ) 0 heights

(* Largest height difference between two neighbouring columns. *)
let max_diff heights =
  let m = ref 0 in
  for x = 0 to board_width - 2 do
    m := max !m (abs (heights.(x) - heights.(x + 1)))
  done;
  !m

(* Holes: empty cells located below the top of their column.
   Returns (number of holes, mean "depth" of the holes, number of "big" holes).

   NOTE (kept as is, the trained weights depend on it, can be change if
         the bot is retrained):
   - "depth" is the row index y of the hole, i.e. its height above the floor.
   - [last_was_full] is never set to false, so [nb_big_holes] always equals
     [nb_holes].
   - An empty column (height 0) is scanned at row 0 and therefore counts one
     hole. *)
let holes_and_mean_depth t heights =
  let nb_holes = ref 0 in
  let nb_big_holes = ref 0 in
  let last_was_full = ref true in
  let depth = ref 0 in
  for x = 0 to board_width - 1 do
    for y = 0 to max (heights.(x) - 1) 0 do
      if not (get_bit t (pos x y)) then begin
        incr nb_holes;
        depth := !depth + y;
        if !last_was_full then incr nb_big_holes
      end else
        last_was_full := true
    done
  done;
  !nb_holes,
  float_of_int !depth /. (float_of_int !nb_holes +. 0.0001),
  !nb_big_holes

(* Number of rows that contain at least one hole. *)
let nb_lines_with_holes t heights =
  let has_hole = Array.make board_height false in
  for x = 0 to board_width - 1 do
    for y = 0 to heights.(x) - 1 do
      if not (get_bit t (pos x y)) then has_hole.(y) <- true
    done
  done;
  Array.fold_left (fun acc b -> if b then acc + 1 else acc) 0 has_hole

(* Number of empty/occupied changes along the rows, below the highest column.
   The walls are not counted. *)
let row_transitions t height =
  let count = ref 0 in
  for y = 0 to height - 1 do
    for x = 0 to board_width - 2 do
      if get_bit t (pos x y) <> get_bit t (pos (x + 1) y) then incr count
    done
  done;
  !count

(* Number of empty/occupied changes along the columns, between the floor and
   the top of each column. *)
let col_transitions t heights =
  let count = ref 0 in
  for x = 0 to board_width - 1 do
    for y = 0 to heights.(x) - 2 do
      if get_bit t (pos x y) <> get_bit t (pos x (y + 1)) then incr count
    done
  done;
  !count

(* Wells: a column lower than both of its neighbours (the walls count as
   columns of height [board_height]). The depth of a well is the gap to its
   lowest neighbour. Returns:
   - the sum over wells of (depth - 1)
   - the sum over wells of depth * (depth + 1) / 2
   - the mean well depth
   - the number of distinct well depths among {1, 2, 3} *)
let wells heights =
  let count_deep = ref 0 in
  let count_square = ref 0 in
  let count = ref 0 in
  let patterns = Array.make 4 0 in
  for x = 0 to board_width - 1 do
    let h_left = if x > 0 then heights.(x - 1) else board_height in
    let h_right = if x < board_width - 1 then heights.(x + 1) else board_height in
    let depth = min h_left h_right - heights.(x) in
    if depth > 0 then begin
      incr count;
      count_square := !count_square + (depth * (depth + 1)) / 2;
      count_deep := !count_deep + depth
    end;
    if depth > 0 && depth < 4 then patterns.(depth) <- 1
  done;
  !count_deep - !count,
  !count_square,
  float_of_int !count_deep /. (float_of_int !count +. 0.0001),
  Array.fold_left ( + ) 0 patterns

(* Distance between the surface and a symmetric reference profile ("bol" is
   French for bowl). The reference is anchored on the mean height of the two
   central columns (3 and 4); for the column pairs (x, 9 - x), x = 0..3, with
   decal = x - 3.5:
   - [bol] compares the pair with the linear profile  h_mid + decal
   - [bol_quad] compares it with the parabolic profile h_mid + decal^2
   Assumes a board width of 10. *)
let bol_and_bol_quad heights =
  let sum = ref 0. in
  let sum_quad = ref 0. in
  let h_mid = float_of_int (heights.(3) + heights.(4)) /. 2. in
  for x = 0 to 3 do
    let decal = float_of_int x -. 3.5 in
    let h_ideal = h_mid +. decal ** 2. in
    let h_bol = h_mid +. decal in
    let h_left = float_of_int heights.(x)
    and h_right = float_of_int heights.(board_width - 1 - x) in
    sum := !sum +. abs_float (h_left +. h_right -. 2. *. h_bol);
    sum_quad := !sum_quad +. abs_float (h_left +. h_right -. 2. *. h_ideal)
  done;
  !sum, !sum_quad

(* Four terms exp(d^2 / div) where d is the gap between the mean column height
   c and k * h / 4 (k = 1..4, h = highest column), and
   div = 2 * (h / 5)^2 + 0.001 (the constant avoids a division by zero on an
   empty board).

   NOTE (kept as is, the trained weights depend on it): the exponent is
   positive, so each term GROWS as c moves away from k * h / 4. It is not a
   Gaussian bump, which would use a minus sign. *)
let exponentals heights max_height =
  let c = float_of_int (sum_height heights) /. float_of_int board_width in
  let h = float_of_int max_height in
  let h4 = h /. 4. in
  let div = 2. *. (h /. 5.) ** 2. +. 0.001 in
  exp (((c -. h4) ** 2.) /. div),
  exp (((c -. 2. *. h4) ** 2.) /. div),
  exp (((c -. 3. *. h4) ** 2.) /. div),
  exp (((c -. 4. *. h4) ** 2.) /. div)

(* ------------------------------------------------------------------------- *)
(* Evaluation function                                                       *)
(* ------------------------------------------------------------------------- *)

(* Names of the 20 features, in the order used by [eval]. Used by genetic.ml to
   display the best individual. *)
let name_params = [|
  "  landing height   ";
  " nb lines cleared  ";
  "    max height     ";
  "  max height diff  ";
  "  row transitions  ";
  "  col transitions  ";
  "     deep wells    ";
  "    wells square   ";
  "     mean wells    ";
  " nb wells patterns ";
  "      holes        ";
  " mean depth holes  ";
  "    nb big holes   ";
  "       bol         ";
  "  bol quadratique  ";
  "nb lines with holes";
  "       exp1        ";
  "       exp2        ";
  "       exp3        ";
  "       exp4        "
|]

(* Cost of the board [t] reached after playing a piece. Lower is better.
   - [ind]              : the 20 weights, indexed as in [name_params]
   - [landing_height]   : landing height of the piece that was just played
   - [nb_lines_cleared] : number of lines cleared by that piece *)
let eval ind t landing_height nb_lines_cleared =
  let heights = get_heights_array t in
  let max_height = height heights in
  let bol, bol_quad = bol_and_bol_quad heights in
  let deep_wells, wells_square, wells_mean, nb_wells_patterns = wells heights in
  let holes, mean_depth_holes, nb_big_holes = holes_and_mean_depth t heights in
  let row_trans = float_of_int (row_transitions t max_height) in
  let exp1, exp2, exp3, exp4 = exponentals heights max_height in
  ind.(0)  *. float_of_int landing_height +.
  ind.(1)  *. float_of_int nb_lines_cleared +.
  ind.(2)  *. float_of_int max_height +.
  ind.(3)  *. float_of_int (max_diff heights) +.
  ind.(4)  *. row_trans +.
  ind.(5)  *. float_of_int (col_transitions t heights) +.
  ind.(6)  *. float_of_int deep_wells +.
  ind.(7)  *. float_of_int wells_square +.
  ind.(8)  *. wells_mean +.
  ind.(9)  *. float_of_int nb_wells_patterns +.
  ind.(10) *. float_of_int holes +.
  ind.(11) *. mean_depth_holes +.
  ind.(12) *. float_of_int nb_big_holes +.
  ind.(13) *. bol +.
  ind.(14) *. bol_quad +.
  ind.(15) *. float_of_int (nb_lines_with_holes t heights) +.
  ind.(16) *. exp1 +.
  ind.(17) *. exp2 +.
  ind.(18) *. exp3 +.
  ind.(19) *. exp4

(* ------------------------------------------------------------------------- *)
(* Bot                                                                       *)
(* ------------------------------------------------------------------------- *)

(* Best placement (x, d) for piece number [piece_index] on the board [t]:
   x is the anchor column and d the number of rotations. Every placement is
   simulated on a copy of the board and scored with [eval] (lowest cost wins,
   the first one wins ties). Returns (0, 0) if no placement is possible. *)
let best_placement indiv piece_index t eval =
  let best = ref (0, 0) and best_cost = ref infinity in
  for d = 0 to num_rotations.(piece_index) - 1 do
    let rotated = pieces_rotations.(piece_index).(d) in
    let xmin, xmax = pieces_placement.(piece_index).(d) in
    for x = xmin to xmax do
      let board = Bytes.copy t in
      let y = stop rotated board x in
      if y <> -1 then begin
        let landing_height = place_piece rotated board x y in
        let nb_lines_cleared = clear_lines board in
        let cost = eval indiv board landing_height nb_lines_cleared in
        if cost < !best_cost then begin
          best := (x, d);
          best_cost := cost
        end
      end
    done
  done;
  !best

(* ------------------------------------------------------------------------- *)
(* Simulation                                                                *)
(* ------------------------------------------------------------------------- *)

(* Play one game with the weights [indiv] on an empty board. Pieces are drawn
   uniformly at random from the generator seeded with [seed]. The game ends
   when the chosen piece cannot be placed. Returns the total number of lines
   cleared. *)
let play_game indiv seed eval =
  Random.init seed;
  let board = Bytes.make board_bytes '\000' in
  let rec play total_lines =
    let k = Random.int 7 in
    let x, d = best_placement indiv k board eval in
    let piece = pieces_rotations.(k).(d) in
    match stop piece board x with
    | -1 -> total_lines
    | y ->
        ignore (place_piece piece board x y);
        play (total_lines + clear_lines board)
  in
  play 0

(* Fitness of an individual: the mean number of lines cleared over [nb_games]
   random games. Returns (fitness, true); the boolean means "fully evaluated"
   and is only kept for genetic.ml. [_last_average] is unused: it belonged to a
   pruning rule that stopped evaluating unpromising individuals early. *)
let mean_score indiv nb_games eval _last_average =
  Random.self_init ();
  let sum = ref 0. in
  for _game = 1 to nb_games do
    let seed = Random.int 1073741823 in
    sum := !sum +. float_of_int (play_game indiv seed eval)
  done;
  (!sum /. float_of_int nb_games, true)

(* ------------------------------------------------------------------------- *)
(* Debugging                                                                 *)
(* ------------------------------------------------------------------------- *)

(* Print the board in the terminal. *)
let print_wall t =
  let block =
    if support_ANSI && support_UNICODE then "\027[34m\xe2\x96\xa0\027[39m"
    else "X"
  in
  print_newline ();
  for y = board_height - 1 downto 0 do
    print_string "|";
    for x = 0 to board_width - 1 do
      print_string (if get_bit t (pos x y) then block else " ")
    done;
    print_string "|\n"
  done;
  print_string "+----------+\n"