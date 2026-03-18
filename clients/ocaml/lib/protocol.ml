(** Minimal msgpack encoder/decoder for kgd msgpack-RPC. *)

type t =
  | Nil
  | Bool of bool
  | Int of int
  | Str of string
  | Bin of bytes
  | Array of t list
  | Map of (t * t) list

(* -------------------------------------------------------------------------- *)
(* Encoding                                                                   *)
(* -------------------------------------------------------------------------- *)

let buf_add_uint8 buf v = Buffer.add_char buf (Char.chr (v land 0xff))

let buf_add_uint16_be buf v =
  Buffer.add_char buf (Char.chr ((v lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (v land 0xff))

let buf_add_uint32_be buf v =
  Buffer.add_char buf (Char.chr ((v lsr 24) land 0xff));
  Buffer.add_char buf (Char.chr ((v lsr 16) land 0xff));
  Buffer.add_char buf (Char.chr ((v lsr 8) land 0xff));
  Buffer.add_char buf (Char.chr (v land 0xff))

let encode_int buf n =
  if n >= 0 then begin
    if n <= 0x7f then
      (* positive fixint *)
      buf_add_uint8 buf n
    else if n <= 0xff then begin
      (* uint 8 *)
      buf_add_uint8 buf 0xcc;
      buf_add_uint8 buf n
    end
    else if n <= 0xffff then begin
      (* uint 16 *)
      buf_add_uint8 buf 0xcd;
      buf_add_uint16_be buf n
    end
    else begin
      (* uint 32 *)
      buf_add_uint8 buf 0xce;
      buf_add_uint32_be buf n
    end
  end
  else begin
    if n >= -32 then
      (* negative fixint *)
      buf_add_uint8 buf (n land 0xff)
    else if n >= -128 then begin
      (* int 8 *)
      buf_add_uint8 buf 0xd0;
      buf_add_uint8 buf (n land 0xff)
    end
    else if n >= -32768 then begin
      (* int 16 *)
      buf_add_uint8 buf 0xd1;
      buf_add_uint16_be buf (n land 0xffff)
    end
    else begin
      (* int 32 *)
      buf_add_uint8 buf 0xd2;
      buf_add_uint32_be buf (n land 0xffffffff)
    end
  end

let encode_str buf s =
  let len = String.length s in
  if len <= 31 then begin
    (* fixstr *)
    buf_add_uint8 buf (0xa0 lor len)
  end
  else if len <= 0xff then begin
    (* str 8 *)
    buf_add_uint8 buf 0xd9;
    buf_add_uint8 buf len
  end
  else if len <= 0xffff then begin
    (* str 16 *)
    buf_add_uint8 buf 0xda;
    buf_add_uint16_be buf len
  end
  else begin
    (* str 32 *)
    buf_add_uint8 buf 0xdb;
    buf_add_uint32_be buf len
  end;
  Buffer.add_string buf s

let encode_bin buf b =
  let len = Bytes.length b in
  if len <= 0xff then begin
    (* bin 8 *)
    buf_add_uint8 buf 0xc4;
    buf_add_uint8 buf len
  end
  else if len <= 0xffff then begin
    (* bin 16 *)
    buf_add_uint8 buf 0xc5;
    buf_add_uint16_be buf len
  end
  else begin
    (* bin 32 *)
    buf_add_uint8 buf 0xc6;
    buf_add_uint32_be buf len
  end;
  Buffer.add_bytes buf b

let encode_array_header buf len =
  if len <= 15 then
    (* fixarray *)
    buf_add_uint8 buf (0x90 lor len)
  else if len <= 0xffff then begin
    (* array 16 *)
    buf_add_uint8 buf 0xdc;
    buf_add_uint16_be buf len
  end
  else begin
    (* array 32 *)
    buf_add_uint8 buf 0xdd;
    buf_add_uint32_be buf len
  end

let encode_map_header buf len =
  if len <= 15 then
    (* fixmap *)
    buf_add_uint8 buf (0x80 lor len)
  else if len <= 0xffff then begin
    (* map 16 *)
    buf_add_uint8 buf 0xde;
    buf_add_uint16_be buf len
  end
  else begin
    (* map 32 *)
    buf_add_uint8 buf 0xdf;
    buf_add_uint32_be buf len
  end

let rec encode_to_buf buf = function
  | Nil -> buf_add_uint8 buf 0xc0
  | Bool true -> buf_add_uint8 buf 0xc3
  | Bool false -> buf_add_uint8 buf 0xc2
  | Int n -> encode_int buf n
  | Str s -> encode_str buf s
  | Bin b -> encode_bin buf b
  | Array elts ->
      encode_array_header buf (List.length elts);
      List.iter (encode_to_buf buf) elts
  | Map pairs ->
      encode_map_header buf (List.length pairs);
      List.iter
        (fun (k, v) ->
          encode_to_buf buf k;
          encode_to_buf buf v)
        pairs

let encode v =
  let buf = Buffer.create 256 in
  encode_to_buf buf v;
  Buffer.to_bytes buf

(* -------------------------------------------------------------------------- *)
(* Decoding                                                                   *)
(* -------------------------------------------------------------------------- *)

let get_uint8 buf ofs =
  if ofs >= Bytes.length buf then failwith "msgpack: unexpected end of input";
  Char.code (Bytes.get buf ofs)

let get_uint16_be buf ofs =
  if ofs + 1 >= Bytes.length buf then
    failwith "msgpack: unexpected end of input";
  (Char.code (Bytes.get buf ofs) lsl 8) lor Char.code (Bytes.get buf (ofs + 1))

let get_uint32_be buf ofs =
  if ofs + 3 >= Bytes.length buf then
    failwith "msgpack: unexpected end of input";
  (Char.code (Bytes.get buf ofs) lsl 24)
  lor (Char.code (Bytes.get buf (ofs + 1)) lsl 16)
  lor (Char.code (Bytes.get buf (ofs + 2)) lsl 8)
  lor Char.code (Bytes.get buf (ofs + 3))

let get_int8 buf ofs =
  let v = get_uint8 buf ofs in
  if v >= 128 then v - 256 else v

let get_int16_be buf ofs =
  let v = get_uint16_be buf ofs in
  if v >= 32768 then v - 65536 else v

let get_int32_be buf ofs =
  let v = get_uint32_be buf ofs in
  (* On 64-bit OCaml, sign-extend from 32 bits *)
  if v > 0x7fffffff then v - (1 lsl 32) else v

let get_bytes buf ofs len =
  if ofs + len > Bytes.length buf then
    failwith "msgpack: unexpected end of input";
  Bytes.sub buf ofs len

let get_string buf ofs len =
  if ofs + len > Bytes.length buf then
    failwith "msgpack: unexpected end of input";
  Bytes.sub_string buf ofs len

let rec decode buf ofs =
  let tag = get_uint8 buf ofs in
  let ofs = ofs + 1 in
  if tag <= 0x7f then
    (* positive fixint *)
    (Int tag, ofs)
  else if tag >= 0xe0 then
    (* negative fixint *)
    (Int (tag - 256), ofs)
  else if tag >= 0xa0 && tag <= 0xbf then begin
    (* fixstr *)
    let len = tag land 0x1f in
    let s = get_string buf ofs len in
    (Str s, ofs + len)
  end
  else if tag >= 0x90 && tag <= 0x9f then begin
    (* fixarray *)
    let len = tag land 0x0f in
    decode_array buf ofs len
  end
  else if tag >= 0x80 && tag <= 0x8f then begin
    (* fixmap *)
    let len = tag land 0x0f in
    decode_map buf ofs len
  end
  else
    match tag with
    | 0xc0 -> (Nil, ofs)
    | 0xc2 -> (Bool false, ofs)
    | 0xc3 -> (Bool true, ofs)
    (* bin 8 *)
    | 0xc4 ->
        let len = get_uint8 buf ofs in
        let b = get_bytes buf (ofs + 1) len in
        (Bin b, ofs + 1 + len)
    (* bin 16 *)
    | 0xc5 ->
        let len = get_uint16_be buf ofs in
        let b = get_bytes buf (ofs + 2) len in
        (Bin b, ofs + 2 + len)
    (* bin 32 *)
    | 0xc6 ->
        let len = get_uint32_be buf ofs in
        let b = get_bytes buf (ofs + 4) len in
        (Bin b, ofs + 4 + len)
    (* uint 8 *)
    | 0xcc ->
        let v = get_uint8 buf ofs in
        (Int v, ofs + 1)
    (* uint 16 *)
    | 0xcd ->
        let v = get_uint16_be buf ofs in
        (Int v, ofs + 2)
    (* uint 32 *)
    | 0xce ->
        let v = get_uint32_be buf ofs in
        (Int v, ofs + 4)
    (* int 8 *)
    | 0xd0 ->
        let v = get_int8 buf ofs in
        (Int v, ofs + 1)
    (* int 16 *)
    | 0xd1 ->
        let v = get_int16_be buf ofs in
        (Int v, ofs + 2)
    (* int 32 *)
    | 0xd2 ->
        let v = get_int32_be buf ofs in
        (Int v, ofs + 4)
    (* str 8 *)
    | 0xd9 ->
        let len = get_uint8 buf ofs in
        let s = get_string buf (ofs + 1) len in
        (Str s, ofs + 1 + len)
    (* str 16 *)
    | 0xda ->
        let len = get_uint16_be buf ofs in
        let s = get_string buf (ofs + 2) len in
        (Str s, ofs + 2 + len)
    (* str 32 *)
    | 0xdb ->
        let len = get_uint32_be buf ofs in
        let s = get_string buf (ofs + 4) len in
        (Str s, ofs + 4 + len)
    (* array 16 *)
    | 0xdc ->
        let len = get_uint16_be buf ofs in
        decode_array buf (ofs + 2) len
    (* array 32 *)
    | 0xdd ->
        let len = get_uint32_be buf ofs in
        decode_array buf (ofs + 4) len
    (* map 16 *)
    | 0xde ->
        let len = get_uint16_be buf ofs in
        decode_map buf (ofs + 2) len
    (* map 32 *)
    | 0xdf ->
        let len = get_uint32_be buf ofs in
        decode_map buf (ofs + 4) len
    | _ ->
        failwith (Printf.sprintf "msgpack: unsupported format byte 0x%02x" tag)

and decode_array buf ofs len =
  let rec loop ofs acc remaining =
    if remaining = 0 then (Array (List.rev acc), ofs)
    else
      let v, ofs' = decode buf ofs in
      loop ofs' (v :: acc) (remaining - 1)
  in
  loop ofs [] len

and decode_map buf ofs len =
  let rec loop ofs acc remaining =
    if remaining = 0 then (Map (List.rev acc), ofs)
    else
      let k, ofs' = decode buf ofs in
      let v, ofs'' = decode buf ofs' in
      loop ofs'' ((k, v) :: acc) (remaining - 1)
  in
  loop ofs [] len

let decode_all buf =
  let total = Bytes.length buf in
  let rec loop ofs acc =
    if ofs >= total then List.rev acc
    else
      let v, ofs' = decode buf ofs in
      loop ofs' (v :: acc)
  in
  loop 0 []

(* -------------------------------------------------------------------------- *)
(* Convenience accessors                                                      *)
(* -------------------------------------------------------------------------- *)

let to_int = function Int n -> n | _ -> 0
let to_string = function Str s -> s | _ -> ""
let to_bool = function Bool b -> b | _ -> false
let to_list = function Array l -> l | _ -> []

let to_assoc = function
  | Map pairs ->
      List.filter_map
        (fun (k, v) -> match k with Str s -> Some (s, v) | _ -> None)
        pairs
  | _ -> []

let lookup key = function
  | Map pairs -> (
      match List.find_opt (fun (k, _) -> k = Str key) pairs with
      | Some (_, v) -> v
      | None -> Nil)
  | _ -> Nil
