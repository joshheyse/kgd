(** Client library for kgd (Kitty Graphics Daemon). *)

module P = Protocol

(* -------------------------------------------------------------------------- *)
(* Types                                                                      *)
(* -------------------------------------------------------------------------- *)

type color = {
  r : int;
  g : int;
  b : int;
}

type anchor =
  | Absolute of { row : int; col : int }
  | Tmux_pane of { pane_id : string; row : int; col : int }
  | Nvim_win of { win_id : int; pane_id : string; buf_line : int; col : int }

type placement_info = {
  placement_id : int;
  client_id : string;
  handle : int;
  visible : bool;
  row : int;
  col : int;
}

type status_result = {
  clients : int;
  placements : int;
  images : int;
  cols : int;
  rows : int;
}

type place_opts = {
  src_x : int;
  src_y : int;
  src_w : int;
  src_h : int;
  z_index : int;
}

(* msgpack-rpc message types *)
let _MSG_REQUEST = 0
let _MSG_RESPONSE = 1
let _MSG_NOTIFICATION = 2

(* Pending response state: a mutex + condition variable pair *)
type pending = {
  mtx : Mutex.t;
  cond : Condition.t;
  mutable resolved : bool;
  mutable error : P.t;
  mutable result : P.t;
}

type t = {
  sock : Unix.file_descr;
  write_lock : Mutex.t;
  pending_lock : Mutex.t;
  mutable next_id : int;
  pending : (int, pending) Hashtbl.t;
  mutable done_ : bool;
  mutable reader_thread : Thread.t option;

  (* Hello result *)
  mutable client_id : string;
  mutable cols : int;
  mutable rows : int;
  mutable cell_width : int;
  mutable cell_height : int;
  mutable in_tmux : bool;
  mutable fg : color;
  mutable bg : color;

  (* Notification callbacks *)
  mutable on_evicted : (int -> unit) option;
  mutable on_topology_changed : (int -> int -> int -> int -> unit) option;
  mutable on_visibility_changed : (int -> bool -> unit) option;
  mutable on_theme_changed : (color -> color -> unit) option;
}

(* -------------------------------------------------------------------------- *)
(* Helpers                                                                    *)
(* -------------------------------------------------------------------------- *)

let color_zero = { r = 0; g = 0; b = 0 }

let color_of_msgpack v =
  let assoc = P.to_assoc v in
  {
    r = P.to_int (List.assoc_opt "r" assoc |> Option.value ~default:P.Nil);
    g = P.to_int (List.assoc_opt "g" assoc |> Option.value ~default:P.Nil);
    b = P.to_int (List.assoc_opt "b" assoc |> Option.value ~default:P.Nil);
  }

let anchor_to_msgpack = function
  | Absolute { row; col } ->
    let pairs = [ (P.Str "type", P.Str "absolute") ] in
    let pairs = if row <> 0 then pairs @ [ (P.Str "row", P.Int row) ] else pairs in
    let pairs = if col <> 0 then pairs @ [ (P.Str "col", P.Int col) ] else pairs in
    P.Map pairs
  | Tmux_pane { pane_id; row; col } ->
    let pairs = [ (P.Str "type", P.Str "tmux_pane") ] in
    let pairs = if pane_id <> "" then pairs @ [ (P.Str "pane_id", P.Str pane_id) ] else pairs in
    let pairs = if row <> 0 then pairs @ [ (P.Str "row", P.Int row) ] else pairs in
    let pairs = if col <> 0 then pairs @ [ (P.Str "col", P.Int col) ] else pairs in
    P.Map pairs
  | Nvim_win { win_id; pane_id; buf_line; col } ->
    let pairs = [ (P.Str "type", P.Str "nvim_win") ] in
    let pairs = if pane_id <> "" then pairs @ [ (P.Str "pane_id", P.Str pane_id) ] else pairs in
    let pairs = if win_id <> 0 then pairs @ [ (P.Str "win_id", P.Int win_id) ] else pairs in
    let pairs = if buf_line <> 0 then pairs @ [ (P.Str "buf_line", P.Int buf_line) ] else pairs in
    let pairs = if col <> 0 then pairs @ [ (P.Str "col", P.Int col) ] else pairs in
    P.Map pairs

(** Build a map from string-value pairs, omitting entries where value is zero/empty. *)
let map_of_pairs pairs =
  P.Map (List.map (fun (k, v) -> (P.Str k, v)) pairs)

(* -------------------------------------------------------------------------- *)
(* Socket path resolution                                                     *)
(* -------------------------------------------------------------------------- *)

let default_socket_path () =
  let runtime_dir =
    match Sys.getenv_opt "XDG_RUNTIME_DIR" with
    | Some d when d <> "" -> d
    | _ -> Filename.get_temp_dir_name ()
  in
  let kitty_id =
    match Sys.getenv_opt "KITTY_WINDOW_ID" with
    | Some id when id <> "" -> id
    | _ -> "default"
  in
  Filename.concat runtime_dir (Printf.sprintf "kgd-%s.sock" kitty_id)

let resolve_socket_path path =
  match path with
  | Some p when p <> "" -> p
  | _ ->
    match Sys.getenv_opt "KGD_SOCKET" with
    | Some p when p <> "" -> p
    | _ -> default_socket_path ()

(* -------------------------------------------------------------------------- *)
(* Daemon auto-launch                                                         *)
(* -------------------------------------------------------------------------- *)

let ensure_daemon socket_path =
  (* Try to connect to see if daemon is running *)
  let try_connect () =
    try
      let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      (try
         Unix.connect fd (Unix.ADDR_UNIX socket_path);
         Unix.close fd;
         true
       with _ ->
         Unix.close fd;
         false)
    with _ -> false
  in
  if try_connect () then ()
  else begin
    (* Find kgd binary *)
    let kgd_path =
      let paths = String.split_on_char ':' (Sys.getenv_opt "PATH" |> Option.value ~default:"") in
      let rec find = function
        | [] -> failwith "kgd not found in PATH"
        | dir :: rest ->
          let p = Filename.concat dir "kgd" in
          if Sys.file_exists p then p else find rest
      in
      find paths
    in
    (* Start daemon in background *)
    let _pid = Unix.create_process kgd_path
        [| kgd_path; "serve"; "--socket"; socket_path |]
        Unix.stdin Unix.stdout Unix.stderr
    in
    (* Wait up to 5 seconds for daemon to start *)
    let rec wait n =
      if n <= 0 then failwith "timed out waiting for kgd to start"
      else begin
        Unix.sleepf 0.1;
        if try_connect () then ()
        else wait (n - 1)
      end
    in
    wait 50
  end

(* -------------------------------------------------------------------------- *)
(* Send / receive                                                             *)
(* -------------------------------------------------------------------------- *)

let send_raw client data =
  Mutex.lock client.write_lock;
  Fun.protect ~finally:(fun () -> Mutex.unlock client.write_lock) (fun () ->
    let total = Bytes.length data in
    let rec loop sent =
      if sent < total then begin
        let n = Unix.write client.sock data sent (total - sent) in
        loop (sent + n)
      end
    in
    loop 0
  )

let send_request client msg_id method_name params =
  let params_array = match params with
    | P.Nil -> P.Array []
    | p -> P.Array [ p ]
  in
  let msg = P.Array [
    P.Int _MSG_REQUEST;
    P.Int msg_id;
    P.Str method_name;
    params_array;
  ] in
  send_raw client (P.encode msg)

let send_notification client method_name params =
  let params_array = match params with
    | P.Nil -> P.Array []
    | p -> P.Array [ p ]
  in
  let msg = P.Array [
    P.Int _MSG_NOTIFICATION;
    P.Str method_name;
    params_array;
  ] in
  send_raw client (P.encode msg)

(* -------------------------------------------------------------------------- *)
(* Background reader                                                          *)
(* -------------------------------------------------------------------------- *)

let handle_response client msg =
  let elts = P.to_list msg in
  match elts with
  | [ _; msg_id_v; err_v; result_v ] ->
    let msg_id = P.to_int msg_id_v in
    Mutex.lock client.pending_lock;
    let p = Hashtbl.find_opt client.pending msg_id in
    Mutex.unlock client.pending_lock;
    (match p with
     | Some pending ->
       Mutex.lock pending.mtx;
       pending.error <- err_v;
       pending.result <- result_v;
       pending.resolved <- true;
       Condition.signal pending.cond;
       Mutex.unlock pending.mtx
     | None -> ())
  | _ -> ()

let handle_notification client msg =
  let elts = P.to_list msg in
  match elts with
  | [ _; method_v; params_arr_v ] ->
    let method_name = P.to_string method_v in
    let params_list = P.to_list params_arr_v in
    let params = match params_list with
      | p :: _ -> p
      | [] -> P.Nil
    in
    (match method_name with
     | "evicted" ->
       (match client.on_evicted with
        | Some cb -> cb (P.to_int (P.lookup "handle" params))
        | None -> ())
     | "topology_changed" ->
       (match client.on_topology_changed with
        | Some cb ->
          cb
            (P.to_int (P.lookup "cols" params))
            (P.to_int (P.lookup "rows" params))
            (P.to_int (P.lookup "cell_width" params))
            (P.to_int (P.lookup "cell_height" params))
        | None -> ())
     | "visibility_changed" ->
       (match client.on_visibility_changed with
        | Some cb ->
          cb
            (P.to_int (P.lookup "placement_id" params))
            (P.to_bool (P.lookup "visible" params))
        | None -> ())
     | "theme_changed" ->
       (match client.on_theme_changed with
        | Some cb ->
          let fg_v = P.lookup "fg" params in
          let bg_v = P.lookup "bg" params in
          let fg = match fg_v with P.Nil -> color_zero | _ -> color_of_msgpack fg_v in
          let bg = match bg_v with P.Nil -> color_zero | _ -> color_of_msgpack bg_v in
          cb fg bg
        | None -> ())
     | _ -> ())
  | _ -> ()

let read_loop client =
  let read_buf = Bytes.create 65536 in
  (* Accumulation buffer for incomplete msgpack messages *)
  let accum = Buffer.create 65536 in
  (try
     while not client.done_ do
       let n = Unix.read client.sock read_buf 0 (Bytes.length read_buf) in
       if n = 0 then begin
         client.done_ <- true
       end else begin
         Buffer.add_subbytes accum read_buf 0 n;
         (* Try to decode as many complete messages as possible *)
         let data = Buffer.to_bytes accum in
         let total = Bytes.length data in
         let rec decode_loop ofs =
           if ofs >= total then ofs
           else
             match P.decode data ofs with
             | (msg, next_ofs) ->
               let elts = P.to_list msg in
               (match elts with
                | P.Int typ :: _ when typ = _MSG_RESPONSE ->
                  handle_response client msg
                | P.Int typ :: _ when typ = _MSG_NOTIFICATION ->
                  handle_notification client msg
                | _ -> ());
               decode_loop next_ofs
             | exception Failure _ ->
               (* Incomplete message, stop *)
               ofs
         in
         let consumed = decode_loop 0 in
         (* Keep unconsumed bytes in the accumulation buffer *)
         Buffer.clear accum;
         if consumed < total then
           Buffer.add_subbytes accum data consumed (total - consumed)
       end
     done
   with
   | Unix.Unix_error _ -> ()
   | Failure _ -> ());
  client.done_ <- true;
  (* Wake up any pending calls *)
  Mutex.lock client.pending_lock;
  Hashtbl.iter (fun _id p ->
    Mutex.lock p.mtx;
    p.resolved <- true;
    Condition.broadcast p.cond;
    Mutex.unlock p.mtx
  ) client.pending;
  Mutex.unlock client.pending_lock

(* -------------------------------------------------------------------------- *)
(* RPC call                                                                   *)
(* -------------------------------------------------------------------------- *)

let call client method_name params ?(timeout=10.0) () =
  Mutex.lock client.pending_lock;
  let msg_id = client.next_id in
  client.next_id <- client.next_id + 1;
  let p = {
    mtx = Mutex.create ();
    cond = Condition.create ();
    resolved = false;
    error = P.Nil;
    result = P.Nil;
  } in
  Hashtbl.replace client.pending msg_id p;
  Mutex.unlock client.pending_lock;
  let timed_out = ref false in
  (* Spawn a timeout thread that signals after [timeout] seconds.
     OCaml 4.x Condition.wait has no timeout parameter, so we use
     a background thread to break the wait. *)
  let _timer = Thread.create (fun () ->
    Unix.sleepf timeout;
    Mutex.lock p.mtx;
    if not p.resolved then begin
      timed_out := true;
      p.resolved <- true;
      Condition.signal p.cond
    end;
    Mutex.unlock p.mtx
  ) () in
  Fun.protect ~finally:(fun () ->
    Mutex.lock client.pending_lock;
    Hashtbl.remove client.pending msg_id;
    Mutex.unlock client.pending_lock
  ) (fun () ->
    send_request client msg_id method_name params;
    Mutex.lock p.mtx;
    while not p.resolved do
      Condition.wait p.cond p.mtx
    done;
    let err = p.error in
    let result = p.result in
    Mutex.unlock p.mtx;
    if !timed_out then
      failwith (Printf.sprintf "RPC call %s timed out" method_name);
    if client.done_ then failwith "connection closed";
    (match err with
     | P.Nil -> result
     | P.Map _ ->
       let msg = P.to_string (P.lookup "message" err) in
       if msg <> "" then failwith msg
       else failwith (Printf.sprintf "RPC error: %s" method_name)
     | _ -> failwith (Printf.sprintf "RPC error: %s" method_name))
  )

let notify client method_name params =
  send_notification client method_name params

(* -------------------------------------------------------------------------- *)
(* Public API                                                                 *)
(* -------------------------------------------------------------------------- *)

let connect ?(socket_path="") ?(session_id="") ?(client_type="") ?(label="")
    ?(auto_launch=true) () =
  let path = resolve_socket_path (if socket_path = "" then None else Some socket_path) in
  if auto_launch then ensure_daemon path;
  let fd = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  (try Unix.connect fd (Unix.ADDR_UNIX path)
   with exn -> Unix.close fd; raise exn);
  let client = {
    sock = fd;
    write_lock = Mutex.create ();
    pending_lock = Mutex.create ();
    next_id = 0;
    pending = Hashtbl.create 16;
    done_ = false;
    reader_thread = None;
    client_id = "";
    cols = 0;
    rows = 0;
    cell_width = 0;
    cell_height = 0;
    in_tmux = false;
    fg = color_zero;
    bg = color_zero;
    on_evicted = None;
    on_topology_changed = None;
    on_visibility_changed = None;
    on_theme_changed = None;
  } in
  client.reader_thread <- Some (Thread.create read_loop client);
  (* Send hello *)
  let hello_params =
    let pairs = [
      (P.Str "client_type", P.Str client_type);
      (P.Str "pid", P.Int (Unix.getpid ()));
      (P.Str "label", P.Str label);
    ] in
    let pairs =
      if session_id <> "" then pairs @ [ (P.Str "session_id", P.Str session_id) ]
      else pairs
    in
    P.Map pairs
  in
  let result = call client "hello" hello_params () in
  client.client_id <- P.to_string (P.lookup "client_id" result);
  client.cols <- P.to_int (P.lookup "cols" result);
  client.rows <- P.to_int (P.lookup "rows" result);
  client.cell_width <- P.to_int (P.lookup "cell_width" result);
  client.cell_height <- P.to_int (P.lookup "cell_height" result);
  client.in_tmux <- P.to_bool (P.lookup "in_tmux" result);
  (match P.lookup "fg" result with
   | P.Nil -> ()
   | fg_v -> client.fg <- color_of_msgpack fg_v);
  (match P.lookup "bg" result with
   | P.Nil -> ()
   | bg_v -> client.bg <- color_of_msgpack bg_v);
  client

let close client =
  client.done_ <- true;
  (try Unix.close client.sock with Unix.Unix_error _ -> ());
  (match client.reader_thread with
   | Some t -> (try Thread.join t with _ -> ())
   | None -> ())

let client_id client = client.client_id
let cols client = client.cols
let rows client = client.rows
let cell_width client = client.cell_width
let cell_height client = client.cell_height
let in_tmux client = client.in_tmux
let fg client = client.fg
let bg client = client.bg

let set_on_evicted client cb = client.on_evicted <- Some cb
let set_on_topology_changed client cb = client.on_topology_changed <- Some cb
let set_on_visibility_changed client cb = client.on_visibility_changed <- Some cb
let set_on_theme_changed client cb = client.on_theme_changed <- Some cb

let upload client data ~format ~width ~height =
  let params = map_of_pairs [
    ("data", P.Bin data);
    ("format", P.Str format);
    ("width", P.Int width);
    ("height", P.Int height);
  ] in
  let result = call client "upload" params () in
  P.to_int (P.lookup "handle" result)

let place client handle ~anchor ~width ~height ?(opts={ src_x=0; src_y=0; src_w=0; src_h=0; z_index=0 }) () =
  let pairs = [
    ("handle", P.Int handle);
    ("anchor", anchor_to_msgpack anchor);
    ("width", P.Int width);
    ("height", P.Int height);
  ] in
  let pairs = if opts.src_x <> 0 then pairs @ [ ("src_x", P.Int opts.src_x) ] else pairs in
  let pairs = if opts.src_y <> 0 then pairs @ [ ("src_y", P.Int opts.src_y) ] else pairs in
  let pairs = if opts.src_w <> 0 then pairs @ [ ("src_w", P.Int opts.src_w) ] else pairs in
  let pairs = if opts.src_h <> 0 then pairs @ [ ("src_h", P.Int opts.src_h) ] else pairs in
  let pairs = if opts.z_index <> 0 then pairs @ [ ("z_index", P.Int opts.z_index) ] else pairs in
  let params = map_of_pairs pairs in
  let result = call client "place" params () in
  P.to_int (P.lookup "placement_id" result)

let unplace client placement_id =
  let params = map_of_pairs [ ("placement_id", P.Int placement_id) ] in
  ignore (call client "unplace" params ())

let unplace_all client =
  notify client "unplace_all" P.Nil

let free client handle =
  let params = map_of_pairs [ ("handle", P.Int handle) ] in
  ignore (call client "free" params ())

let register_win client ~win_id ?(pane_id="") ~top ~left ~width ~height ~scroll_top () =
  let params = map_of_pairs [
    ("win_id", P.Int win_id);
    ("pane_id", P.Str pane_id);
    ("top", P.Int top);
    ("left", P.Int left);
    ("width", P.Int width);
    ("height", P.Int height);
    ("scroll_top", P.Int scroll_top);
  ] in
  notify client "register_win" params

let update_scroll client ~win_id ~scroll_top =
  let params = map_of_pairs [
    ("win_id", P.Int win_id);
    ("scroll_top", P.Int scroll_top);
  ] in
  notify client "update_scroll" params

let unregister_win client ~win_id =
  let params = map_of_pairs [ ("win_id", P.Int win_id) ] in
  notify client "unregister_win" params

let list_placements client =
  let result = call client "list" P.Nil () in
  let placements_v = P.lookup "placements" result in
  let placements_list = P.to_list placements_v in
  List.filter_map (fun p ->
    match p with
    | P.Map _ ->
      Some {
        placement_id = P.to_int (P.lookup "placement_id" p);
        client_id = P.to_string (P.lookup "client_id" p);
        handle = P.to_int (P.lookup "handle" p);
        visible = P.to_bool (P.lookup "visible" p);
        row = P.to_int (P.lookup "row" p);
        col = P.to_int (P.lookup "col" p);
      }
    | _ -> None
  ) placements_list

let status client =
  let result = call client "status" P.Nil () in
  {
    clients = P.to_int (P.lookup "clients" result);
    placements = P.to_int (P.lookup "placements" result);
    images = P.to_int (P.lookup "images" result);
    cols = P.to_int (P.lookup "cols" result);
    rows = P.to_int (P.lookup "rows" result);
  }

let stop client =
  notify client "stop" P.Nil
