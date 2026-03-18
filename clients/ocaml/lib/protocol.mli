(** Minimal msgpack encoder/decoder for kgd msgpack-RPC.

    Handles the subset of msgpack needed by the kgd protocol:
    fixint, uint8/16/32, int8/16/32, nil, bool, bin8/16/32,
    str8/16/32, fixstr, fixarray, array16, fixmap, map16. *)

(** A msgpack value. *)
type t =
  | Nil
  | Bool of bool
  | Int of int
  | Str of string
  | Bin of bytes
  | Array of t list
  | Map of (t * t) list

(** {2 Encoding} *)

(** [encode v] serializes a msgpack value to bytes. *)
val encode : t -> bytes

(** {2 Decoding} *)

(** [decode buf ofs] decodes one msgpack value starting at offset [ofs] in [buf].
    Returns [(value, next_offset)].
    @raise Failure if the buffer is too short or the format byte is unsupported. *)
val decode : bytes -> int -> t * int

(** [decode_all buf] decodes all msgpack values from [buf].
    Returns a list of decoded values.
    @raise Failure on malformed data. *)
val decode_all : bytes -> t list

(** {2 Convenience accessors} *)

(** [to_int v] extracts an integer, returning 0 for non-integer values. *)
val to_int : t -> int

(** [to_string v] extracts a string, returning [""] for non-string values. *)
val to_string : t -> string

(** [to_bool v] extracts a boolean, returning [false] for non-boolean values. *)
val to_bool : t -> bool

(** [to_list v] extracts an array as a list, returning [[]] for non-array values. *)
val to_list : t -> t list

(** [to_assoc v] extracts a map as an association list with string keys.
    Non-string keys are skipped. Returns [[]] for non-map values. *)
val to_assoc : t -> (string * t) list

(** [lookup key v] looks up [key] in a map value. Returns [Nil] if not found. *)
val lookup : string -> t -> t
