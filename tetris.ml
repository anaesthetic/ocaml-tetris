(* Tetris *)
(* $Id: tetris.ml,v 1.4 2003/11/18 22:51:09 berke Exp $ *)
(* vim:set ts=4: *)
(* By Oguz Berke DURAK *)

open Human
open Allegro
open Printf

type vector = int * int
type rectangle = int * int * int * int
	  
type configuration = {
	m : int;
	n : int;
	p : int;
	q : int;
	i0 : int;
	j0 : int;
	f_i0 : int;
	f_j0 : int;
	s_i0 : int;
	s_j0 : int;
    fall_delay : float
  }

let default_configuration = {
  m = 20;
  n = 10;
  p = 20;
  q = 20;
  i0 = 0;
  j0 = 0;
  f_i0 = 50;
  f_j0 = 300;
  s_i0 = 100;
  s_j0 = 300;
  fall_delay = 0.200 (* s *)
}

let pixel_dimensions c = (c.m * c.p + 50, c.n * c.q + 200)

(* let fall_delay = 0.1250000 (* s *) *)
let compact_delay = 0.250 (* s *)
let shade_variation = 0.300

type input = Left | Right | Rotate | Rotate' | Down | Drop | Pause | Quit
type tile = L | L' | Z | Z' | O | I | T
type rotation = R0 | R1 | R2 | R3
type stone = Human.Color.t option
type control = Paused of control | Dead | Falling of float | Compacting of float * int list

let clockwise = function R0 -> R1 | R1 -> R2 | R2 -> R3 | R3 -> R0
let counter_clockwise = function R0 -> R3 | R1 -> R0 | R2 -> R1 | R3 -> R2
	
(* A     C    CB    BA
   BC   AB     A    C   *)

(*
	| Z  -> [0,0;0,1;1,1;1,2]
	| Z' -> [0,0;0,1;1,1;1,0]
	| T  -> [0,1;1,0;1,1;1,2]
	| O  -> [0,0;0,1;1,1;1,0]
	| L  -> [0,0;1,0;2,0;2,1]
	| L' -> [0,0;1,0;2,0;2,-1]
	| I  -> [0,0;1,0;2,0;3,0] *)

let trans (dx,dy) l = List.map (fun (x,y) -> (x+dx,y+dy)) l

let base_stones = function
| Z  -> trans (-1,-1) [0,0;0,1;1,1;1,2]
| Z' -> trans (-1,-1) [0,1;0,2;1,0;1,1]
| T  -> [-1,0;0,-1;0,0;0,1]
| O  -> [0,0;0,1;1,1;1,0]
| L  -> [-1,0;0,0;1,0;1,1]
| L' -> [-1,0;0,0;1,0;1,-1]
| I  -> [0,0;1,0;2,0;3,0]

let map_of_rotation = function
| R0 -> fun x -> x
| R1 -> fun (i,j) -> (j,-i)
| R2 -> fun (i,j) -> (-i,-j)
| R3 -> fun (i,j) -> (-j,i)

let stones_of_tile (rot,t) = match (rot,t) with
| _,O -> base_stones O
| (R0|R2),(Z|Z'|I) -> base_stones t
| (R1|R3),(Z|Z'|I) -> List.map (map_of_rotation R1) (base_stones t)
| _,_ -> List.map (map_of_rotation rot) (base_stones t)
	
let color_of_tile (_,t) =
  match t with
  | L -> Color.Cyan
  | L' -> Color.Magenta
  | Z -> Color.Red
  | Z' -> Color.Green
  | O -> Color.Blue
  | I -> Color.White
  | T -> Color.Yellow
	  
let height_of_tile = function
	Z -> 2 | Z' -> 2 | T -> 2 | O -> 2 | L -> 3 | L' -> 3 | I -> 3
		
type state = {
	mutable what : control;
	board : stone array array;
	mutable score : int;
    mutable lines : int;
	mutable future : rotation * tile;
	mutable present : rotation * tile;
	mutable position : int * int; (* position of present tile, must be consistent with board *)
    mutable delay : float
  }

let random_tile () =
  R0,
  match Random.int 7 with
	0 -> L | 1 -> L' | 2 -> Z | 3 -> Z' | 4 -> O  | 5 -> I | _ -> T

let initial_state c =
  {
   what = Falling c.fall_delay;
   board = Array.make_matrix c.m c.n None;
   score = 0;
   lines = 0;
   future = random_tile ();
   present = random_tile ();
   position = (1,c.n/2);
   delay = c.fall_delay }

(* c : configuration *)
(* q : current state *)
(* t : time elapsed since last call to this transition function *)
(* k : key pressed *)

let sf = Printf.sprintf
let debug msg = Printf.eprintf "debug: %s\n" msg; flush stderr

let update_board c q t k =
  let k = match k with
  | Some(Keypad.Pressed Keypad.Left) -> Some(Left)
  | Some(Keypad.Pressed Keypad.Right) -> Some(Right)
  | Some(Keypad.Pressed Keypad.Down) -> Some(Down)
  | Some(Keypad.Pressed Keypad.Up) -> Some(Rotate)
  | Some(Keypad.Pressed Keypad.Start) -> Some(Pause)
  | Some(Keypad.Pressed Keypad.L) -> Some(Down)
  | Some(Keypad.Pressed Keypad.R) -> Some(Down)
  | Some(Keypad.Pressed Keypad.Select) -> Some(Drop)
  | _ -> None
  in
  let reset_game () =
	q.what <- Falling c.fall_delay;
	for i = 0 to c.m - 1 do
	  for j = 0 to c.n - 1 do
		q.board.(i).(j) <- None
	  done
	done;
    q.score <- 0;
    q.lines <- 0;
	q.future <- random_tile ();
	q.present <- random_tile ();
	q.position <- (1,c.n/2)
  in
  let occupied i j =
	(i < 0 or j < 0 or i >= c.m or j >= c.n or
	 q.board.(i).(j) <> None)
  in
  let might_occupy t i j = List.for_all (fun (di,dj) -> not (occupied (i + di) (j + dj))) (stones_of_tile t) in
  let blit_stone t i j c =
	List.iter (fun (di,dj) -> q.board.(i + di).(j + dj) <- c) (stones_of_tile t)
  in
  let carve_stone t i j =
	let c = Color.Shade((Random.float (2.0 *. shade_variation)) -. shade_variation, Color.Dark(color_of_tile t)) in
    blit_stone t i j (Some c)
  in
  let place t =
	let (i,j) = q.position in
    let c = color_of_tile t in
    blit_stone t i j (Some c)
  in
  let remove t =
	let (i,j) = q.position in
    blit_stone t i j None
  in
  let next_tile () =
	q.present <- q.future;
	q.future <- random_tile ();
	let (i,j) = (1,c.n/2) in
	q.position <- (i,j);
	if might_occupy q.present i j then
	  begin
		q.what <- Falling(q.delay);
	  end
	else
	  begin
		q.what <- Dead;
	  end
  in
  (* move the piece one position down *)
  (* returns true iff no restriction on horizontal motion could give a valid position, i.e. bottom was reached *)
  let move_piece di k =
	(* piece falls *)
	(* decrease by one *)
	let (i,j) = q.position in
	let i = i + di in
	let (i,j) =
	  match k with
		Some Left when might_occupy q.present i (j - 1) -> (i,j - 1)
	  | Some Right when might_occupy q.present i (j + 1) -> (i,j + 1)
	  | _ -> (i,j)
	in
	if might_occupy q.present i j then
	  begin
		q.position <- (i,j);
		false
	  end
	else
	  true
  in
  let rec check i j = j = c.n or (q.board.(i).(j) <> None && check i (j + 1)) in
  let do_compaction () =
	let rec loop r i =
	  if i = c.m then
		r
	  else
		if check i 0 then
		  loop r (i + 1)
		else
		  loop (i::r) (i + 1)
	in
	let rec loop' i = function
		i'::r ->
		  Array.blit q.board.(i') 0 q.board.(i - 1) 0 c.n;
		  loop' (i - 1) r
	  | [] -> loop'' i
	and loop'' i =
	  if i = 0 then
		()
	  else
		begin
		  Array.fill q.board.(i - 1) 0 c.n None;
		  loop'' (i - 1)
		end
	in
	loop' c.m (loop [] 0);
	next_tile ()
  in
  let reached_bottom () =
    (* piece reached bottom *)
	begin
	  let (i,j) = q.position in
	  carve_stone q.present i j;
	  (* check if any lines are completed *)
	  let rec loop r i =
		if i = c.m then
		  r
		else
		  if check i 0 then
			loop (i::r) (i + 1)
		  else
			loop r (i + 1)
	  in
	  match loop [] 0 with
	  | [] -> next_tile ()
	  | l ->
          let r = List.length l in
          q.lines <- r + q.lines;
          q.score <- r * r + q.score;
		  q.what <- Compacting(compact_delay,l);
	end
  in
  let as_usual t =
	q.what <- Falling(t);
  in
  let attempt_to_rotate_piece ccw =
	let (r,t) = q.present in
	let r' = if ccw then counter_clockwise r else clockwise r in
	let (i,j) = q.position in
	if might_occupy (r',t) i j then
	  q.present <- (r',t)
	else
	  ()
  in
  match (q.what,k) with
  | (Paused c,Some Pause) ->
	  q.what <- c;
  | (Paused _,_) -> ()
  | (_,Some Pause) ->
	  q.what <- Paused q.what;
  | (Falling x,Some Drop) ->
      remove q.present;
      while not (move_piece 1 k) do
        ()
      done;
      place q.present;
      reached_bottom ()
  | (Falling x,_) ->
      remove q.present;
	  let di = match k with Some Down -> 1 | _ -> 0 in
	  begin
		match k with
		  Some Rotate -> attempt_to_rotate_piece true
		| Some Rotate' -> attempt_to_rotate_piece false
		| _ -> ()
	  end;
	  if t < x then
		if move_piece (max 0 di) k then reached_bottom () else as_usual (x -. t)
	  else
        if move_piece 1 k then reached_bottom () else as_usual q.delay;
      place q.present;
  | (Compacting(x,l),None) ->
	  if t < x then
		begin
		  q.what <- Compacting(x -. t,l);
		end
	  else
		do_compaction ()
  | (Compacting(_,_),_) -> do_compaction ()
  | (Dead,Some Drop) ->
	  reset_game ();
  | (Dead,_) -> ()


let corner x y = 10 + 20 * y, 10 + 20 * x

let cell_boundaries x y =
  let x1, y1 = corner x y in
  x1+1, y1+1, x1+19, y1+19

let init_screen width height =
  begin
    try set_gfx_mode GFX_AUTODETECT_WINDOWED width height 0 0;
    with _ ->
      try set_gfx_mode GFX_SAFE width height 0 0;
      with _ ->
        set_gfx_mode GFX_TEXT 0 0 0 0;
        allegro_message("Unable to set any graphic mode\n"^ (get_allegro_error()) ^"\n");
        exit 1;
  end


let allegro_color c =
  let (r, g, b) = Color.rgb_of_color c in
  let s x = int_of_float (255.0 *. x) in
  makecol (s r) (s g) (s b)
;;

let display_board screen cfg q =
  acquire_screen();

  for i = 0 to (cfg.m - 1) do
    for j = 0 to (cfg.n - 1) do
      let col = match q.board.(i).(j) with
      | None -> (makecol 100 100 100)
      | Some c -> allegro_color c
      in
      let x1, y1, x2, y2 = cell_boundaries i j in
      rectfill screen x1 y1 x2 y2 col
    done
  done;

  release_screen()
;;

let () =
  let cfg = default_configuration in
  let (height, width) = pixel_dimensions cfg in
  let q = initial_state cfg in
  Random.init(1000);
  allegro_init();
  install_keyboard();
  install_timer();
  init_screen width height;

  set_palette(get_desktop_palette());

  let screen = get_screen() in
  clear_to_color screen (makecol 0 0 0);

  let s, l, r, u = Keypad.Select, Keypad.Left, Keypad.Right, Keypad.Up in
  let x = [ s; l; l; l; s; u; r; r; r; r; s; l; l; s; r; s; l; l; l; l; l; s; s;
  r; r; r; s; ]
  in
  let apply k =
    let k = Some(Keypad.Pressed k) in
    update_board cfg q 1.0 k;
  in
  List.iter apply x;

  let quit = ref false in
  let c = ref 0 in
  while not(!quit) do
    while keypressed() do
      let k = match readkey_scancode() with
      | KEY_UP    -> Some(Keypad.Pressed Keypad.Up)
      | KEY_DOWN  -> Some(Keypad.Pressed Keypad.Down)
      | KEY_LEFT  -> Some(Keypad.Pressed Keypad.Left)
      | KEY_RIGHT -> Some(Keypad.Pressed Keypad.Right)
      | KEY_ESC   -> Some(Keypad.Pressed Keypad.A)
      | KEY_SPACE -> Some(Keypad.Pressed Keypad.Select)
      | _         -> None
      in
      let t = retrace_count() - !c in
      let tau = (float_of_int t) /. 70.0 in
      update_board cfg q tau k;
      display_board screen cfg q;
      if tau > cfg.fall_delay then c := retrace_count();
      if k = Some(Keypad.Pressed Keypad.A) then quit := true;
    done;
    let t = retrace_count() - !c in
    let tau = (float_of_int t) /. 70.0 in
    if tau > cfg.fall_delay then
      begin
        update_board cfg q tau None;
        display_board screen cfg q;
        c := retrace_count();
      end

  done;
