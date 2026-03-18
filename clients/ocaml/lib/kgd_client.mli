(** Client library for kgd (Kitty Graphics Daemon).

    Communicates with the kgd daemon over a Unix domain socket using msgpack-RPC.

    Usage:
    {[
      let client = Kgd_client.connect ~client_type:"myapp" () in
      let handle = Kgd_client.upload client data ~format:"png" ~width:100 ~height:80 in
      let pid = Kgd_client.place client handle
        ~anchor:(Kgd_client.Absolute { row = 5; col = 10 })
        ~width:20 ~height:15 () in
      Kgd_client.unplace client pid;
      Kgd_client.free client handle;
      Kgd_client.close client
    ]} *)

(** {2 Types} *)

(** RGB color with 16-bit per channel precision. *)
type color = {
  r : int;
  g : int;
  b : int;
}

(** Logical position for a placement. *)
type anchor =
  | Absolute of { row : int; col : int }
  | Tmux_pane of { pane_id : string; row : int; col : int }
  | Nvim_win of { win_id : int; pane_id : string; buf_line : int; col : int }

(** Describes a single active placement. *)
type placement_info = {
  placement_id : int;
  client_id : string;
  handle : int;
  visible : bool;
  row : int;
  col : int;
}

(** Daemon status information. *)
type status_result = {
  clients : int;
  placements : int;
  images : int;
  cols : int;
  rows : int;
}

(** Optional source-region and z-index for [place]. *)
type place_opts = {
  src_x : int;
  src_y : int;
  src_w : int;
  src_h : int;
  z_index : int;
}

(** An active connection to the kgd daemon. *)
type t

(** {2 Connection} *)

(** [connect ?socket_path ?session_id ?client_type ?label ?auto_launch ()]
    opens a connection to the kgd daemon.

    - [socket_path]: override socket path (default: [$KGD_SOCKET] or
      [$XDG_RUNTIME_DIR/kgd-$KITTY_WINDOW_ID.sock])
    - [session_id]: optional session identifier
    - [client_type]: client type string sent in [hello]
    - [label]: human-readable label for this client
    - [auto_launch]: if [true] (default), attempt to start daemon if not running

    @raise Failure on connection or hello errors. *)
val connect :
  ?socket_path:string ->
  ?session_id:string ->
  ?client_type:string ->
  ?label:string ->
  ?auto_launch:bool ->
  unit -> t

(** [close client] shuts down the connection and background reader thread. *)
val close : t -> unit

(** {2 Hello result accessors} *)

(** The client ID assigned by the daemon. *)
val client_id : t -> string

(** Terminal columns reported by the daemon. *)
val cols : t -> int

(** Terminal rows reported by the daemon. *)
val rows : t -> int

(** Cell width in pixels. *)
val cell_width : t -> int

(** Cell height in pixels. *)
val cell_height : t -> int

(** Whether the terminal is inside tmux. *)
val in_tmux : t -> bool

(** Foreground color. *)
val fg : t -> color

(** Background color. *)
val bg : t -> color

(** {2 Notification callbacks}

    Set these before calling methods that might trigger notifications. *)

(** Called when an image is evicted from the daemon cache. Argument is the handle. *)
val set_on_evicted : t -> (int -> unit) -> unit

(** Called when terminal topology changes. Arguments: cols, rows, cell_width, cell_height. *)
val set_on_topology_changed : t -> (int -> int -> int -> int -> unit) -> unit

(** Called when placement visibility changes. Arguments: placement_id, visible. *)
val set_on_visibility_changed : t -> (int -> bool -> unit) -> unit

(** Called when terminal theme changes. Arguments: fg, bg. *)
val set_on_theme_changed : t -> (color -> color -> unit) -> unit

(** {2 RPC methods} *)

(** [upload client data ~format ~width ~height] uploads image data and returns a handle.
    @raise Failure on RPC error. *)
val upload : t -> bytes -> format:string -> width:int -> height:int -> int

(** [place client handle ~anchor ~width ~height ?opts ()] places an image and returns
    a placement ID.
    @raise Failure on RPC error. *)
val place : t -> int -> anchor:anchor -> width:int -> height:int ->
  ?opts:place_opts -> unit -> int

(** [unplace client placement_id] removes a single placement.
    @raise Failure on RPC error. *)
val unplace : t -> int -> unit

(** [unplace_all client] removes all placements for this client (notification, no response). *)
val unplace_all : t -> unit

(** [free client handle] releases an uploaded image handle.
    @raise Failure on RPC error. *)
val free : t -> int -> unit

(** [register_win client ~win_id ?pane_id ~top ~left ~width ~height ~scroll_top ()]
    registers a neovim window geometry (notification, no response). *)
val register_win : t -> win_id:int -> ?pane_id:string -> top:int -> left:int ->
  width:int -> height:int -> scroll_top:int -> unit -> unit

(** [update_scroll client ~win_id ~scroll_top] updates scroll position for a
    registered window (notification, no response). *)
val update_scroll : t -> win_id:int -> scroll_top:int -> unit

(** [unregister_win client ~win_id] unregisters a neovim window
    (notification, no response). *)
val unregister_win : t -> win_id:int -> unit

(** [list_placements client] returns all active placements.
    @raise Failure on RPC error. *)
val list_placements : t -> placement_info list

(** [status client] returns daemon status information.
    @raise Failure on RPC error. *)
val status : t -> status_result

(** [stop client] requests the daemon to shut down (notification, no response). *)
val stop : t -> unit
