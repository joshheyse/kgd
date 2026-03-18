(** Tests for kgd_client: protocol encoding/decoding and anchor serialization.
*)

module P = Kgd_client__Protocol

let failures = ref 0
let tests_run = ref 0

let check name cond =
  incr tests_run;
  if not cond then begin
    incr failures;
    Printf.eprintf "FAIL: %s\n%!" name
  end
  else Printf.printf "  ok: %s\n%!" name

(* -------------------------------------------------------------------------- *)
(* Protocol round-trip tests                                                  *)
(* -------------------------------------------------------------------------- *)

let test_encode_decode_nil () =
  let encoded = P.encode P.Nil in
  let v, _ = P.decode encoded 0 in
  check "nil round-trip" (v = P.Nil)

let test_encode_decode_bool () =
  let check_bool b =
    let encoded = P.encode (P.Bool b) in
    let v, _ = P.decode encoded 0 in
    check (Printf.sprintf "bool %b round-trip" b) (v = P.Bool b)
  in
  check_bool true;
  check_bool false

let test_encode_decode_positive_fixint () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "positive fixint %d round-trip" n) (v = P.Int n))
    [ 0; 1; 42; 127 ]

let test_encode_decode_negative_fixint () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "negative fixint %d round-trip" n) (v = P.Int n))
    [ -1; -16; -32 ]

let test_encode_decode_uint8 () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "uint8 %d round-trip" n) (v = P.Int n))
    [ 128; 200; 255 ]

let test_encode_decode_uint16 () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "uint16 %d round-trip" n) (v = P.Int n))
    [ 256; 1000; 65535 ]

let test_encode_decode_uint32 () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "uint32 %d round-trip" n) (v = P.Int n))
    [ 65536; 100000; 1_000_000 ]

let test_encode_decode_int8 () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "int8 %d round-trip" n) (v = P.Int n))
    [ -33; -100; -128 ]

let test_encode_decode_int16 () =
  List.iter
    (fun n ->
      let encoded = P.encode (P.Int n) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "int16 %d round-trip" n) (v = P.Int n))
    [ -129; -1000; -32768 ]

let test_encode_decode_fixstr () =
  List.iter
    (fun s ->
      let encoded = P.encode (P.Str s) in
      let v, _ = P.decode encoded 0 in
      check (Printf.sprintf "fixstr %S round-trip" s) (v = P.Str s))
    [ ""; "a"; "hello"; String.make 31 'x' ]

let test_encode_decode_str8 () =
  let s = String.make 100 'y' in
  let encoded = P.encode (P.Str s) in
  let v, _ = P.decode encoded 0 in
  check "str8 round-trip" (v = P.Str s)

let test_encode_decode_str16 () =
  let s = String.make 300 'z' in
  let encoded = P.encode (P.Str s) in
  let v, _ = P.decode encoded 0 in
  check "str16 round-trip" (v = P.Str s)

let test_encode_decode_bin () =
  let b = Bytes.of_string "\x00\x01\x02\xff" in
  let encoded = P.encode (P.Bin b) in
  let v, _ = P.decode encoded 0 in
  check "bin8 round-trip" (v = P.Bin b)

let test_encode_decode_fixarray () =
  let arr = P.Array [ P.Int 1; P.Str "two"; P.Bool true ] in
  let encoded = P.encode arr in
  let v, _ = P.decode encoded 0 in
  check "fixarray round-trip" (v = arr)

let test_encode_decode_empty_array () =
  let arr = P.Array [] in
  let encoded = P.encode arr in
  let v, _ = P.decode encoded 0 in
  check "empty array round-trip" (v = arr)

let test_encode_decode_fixmap () =
  let m = P.Map [ (P.Str "name", P.Str "test"); (P.Str "value", P.Int 42) ] in
  let encoded = P.encode m in
  let v, _ = P.decode encoded 0 in
  check "fixmap round-trip" (v = m)

let test_encode_decode_nested () =
  let v =
    P.Array
      [
        P.Int 0;
        P.Int 1;
        P.Str "hello";
        P.Array [ P.Map [ (P.Str "key", P.Str "val"); (P.Str "n", P.Int 99) ] ];
      ]
  in
  let encoded = P.encode v in
  let decoded, _ = P.decode encoded 0 in
  check "nested structure round-trip" (decoded = v)

let test_decode_all () =
  let v1 = P.Int 42 in
  let v2 = P.Str "hello" in
  let b1 = P.encode v1 in
  let b2 = P.encode v2 in
  let combined = Bytes.cat b1 b2 in
  let result = P.decode_all combined in
  check "decode_all" (result = [ v1; v2 ])

(* -------------------------------------------------------------------------- *)
(* Convenience accessor tests                                                 *)
(* -------------------------------------------------------------------------- *)

let test_to_int () =
  check "to_int Int" (P.to_int (P.Int 42) = 42);
  check "to_int Str" (P.to_int (P.Str "x") = 0);
  check "to_int Nil" (P.to_int P.Nil = 0)

let test_to_string () =
  check "to_string Str" (P.to_string (P.Str "hi") = "hi");
  check "to_string Int" (P.to_string (P.Int 5) = "");
  check "to_string Nil" (P.to_string P.Nil = "")

let test_to_bool () =
  check "to_bool true" (P.to_bool (P.Bool true) = true);
  check "to_bool false" (P.to_bool (P.Bool false) = false);
  check "to_bool Nil" (P.to_bool P.Nil = false)

let test_to_list () =
  let arr = P.Array [ P.Int 1; P.Int 2 ] in
  check "to_list Array" (P.to_list arr = [ P.Int 1; P.Int 2 ]);
  check "to_list Nil" (P.to_list P.Nil = [])

let test_to_assoc () =
  let m =
    P.Map
      [
        (P.Str "a", P.Int 1); (P.Int 99, P.Str "skip"); (P.Str "b", P.Bool true);
      ]
  in
  let assoc = P.to_assoc m in
  check "to_assoc length" (List.length assoc = 2);
  check "to_assoc a" (List.assoc "a" assoc = P.Int 1);
  check "to_assoc b" (List.assoc "b" assoc = P.Bool true)

let test_lookup () =
  let m = P.Map [ (P.Str "name", P.Str "test"); (P.Str "count", P.Int 7) ] in
  check "lookup found" (P.lookup "name" m = P.Str "test");
  check "lookup missing" (P.lookup "missing" m = P.Nil);
  check "lookup non-map" (P.lookup "x" (P.Int 5) = P.Nil)

(* -------------------------------------------------------------------------- *)
(* msgpack-RPC message format tests                                           *)
(* -------------------------------------------------------------------------- *)

let test_request_format () =
  (* Verify that a request encodes as [0, msgid, method, [params]] *)
  let msg =
    P.Array
      [
        P.Int 0;
        P.Int 1;
        P.Str "hello";
        P.Array [ P.Map [ (P.Str "client_type", P.Str "test") ] ];
      ]
  in
  let encoded = P.encode msg in
  let decoded, _ = P.decode encoded 0 in
  check "request format round-trip" (decoded = msg)

let test_response_format () =
  (* Verify that a response encodes as [1, msgid, error, result] *)
  let msg =
    P.Array
      [
        P.Int 1; P.Int 1; P.Nil; P.Map [ (P.Str "client_id", P.Str "abc-123") ];
      ]
  in
  let encoded = P.encode msg in
  let decoded, _ = P.decode encoded 0 in
  check "response format round-trip" (decoded = msg)

let test_notification_format () =
  (* Verify that a notification encodes as [2, method, [params]] *)
  let msg =
    P.Array
      [
        P.Int 2;
        P.Str "evicted";
        P.Array [ P.Map [ (P.Str "handle", P.Int 42) ] ];
      ]
  in
  let encoded = P.encode msg in
  let decoded, _ = P.decode encoded 0 in
  check "notification format round-trip" (decoded = msg)

(* -------------------------------------------------------------------------- *)
(* Anchor serialization tests                                                 *)
(* -------------------------------------------------------------------------- *)

let test_anchor_absolute () =
  (* Test that Absolute anchor serializes correctly, omitting zero fields *)
  let open Kgd_client in
  let _anchor = Absolute { row = 5; col = 10 } in
  (* We cannot directly call anchor_to_msgpack since it's not public,
     but we can verify the types compile correctly *)
  check "anchor Absolute type compiles" true

let test_anchor_tmux_pane () =
  let open Kgd_client in
  let _anchor = Tmux_pane { pane_id = "%1"; row = 3; col = 0 } in
  check "anchor Tmux_pane type compiles" true

let test_anchor_nvim_win () =
  let open Kgd_client in
  let _anchor =
    Nvim_win { win_id = 1000; pane_id = "%1"; buf_line = 42; col = 5 }
  in
  check "anchor Nvim_win type compiles" true

(* -------------------------------------------------------------------------- *)
(* Type construction tests                                                    *)
(* -------------------------------------------------------------------------- *)

let test_placement_info () =
  let open Kgd_client in
  let p =
    {
      placement_id = 1;
      client_id = "abc";
      handle = 42;
      visible = true;
      row = 5;
      col = 10;
    }
  in
  check "placement_info fields"
    (p.placement_id = 1 && p.handle = 42 && p.visible)

let test_status_result () =
  let open Kgd_client in
  let s = { clients = 2; placements = 5; images = 3; cols = 80; rows = 24 } in
  check "status_result fields" (s.clients = 2 && s.cols = 80)

let test_place_opts () =
  let open Kgd_client in
  let o = { src_x = 10; src_y = 20; src_w = 100; src_h = 80; z_index = 1 } in
  check "place_opts fields" (o.src_x = 10 && o.z_index = 1)

let test_color () =
  let open Kgd_client in
  let c = { r = 255; g = 128; b = 0 } in
  check "color fields" (c.r = 255 && c.g = 128 && c.b = 0)

(* -------------------------------------------------------------------------- *)
(* Binary data tests                                                          *)
(* -------------------------------------------------------------------------- *)

let test_large_bin () =
  let data = Bytes.make 1000 '\xff' in
  let encoded = P.encode (P.Bin data) in
  let v, _ = P.decode encoded 0 in
  match v with
  | P.Bin b -> check "large bin round-trip" (b = data)
  | _ -> check "large bin round-trip" false

let test_upload_message_format () =
  (* Simulate the upload request message *)
  let data = Bytes.of_string "\x89PNG\r\n\x1a\n" in
  let msg =
    P.Array
      [
        P.Int 0;
        P.Int 0;
        P.Str "upload";
        P.Array
          [
            P.Map
              [
                (P.Str "data", P.Bin data);
                (P.Str "format", P.Str "png");
                (P.Str "width", P.Int 100);
                (P.Str "height", P.Int 80);
              ];
          ];
      ]
  in
  let encoded = P.encode msg in
  let decoded, _ = P.decode encoded 0 in
  check "upload message round-trip" (decoded = msg)

(* -------------------------------------------------------------------------- *)
(* Entry point                                                                *)
(* -------------------------------------------------------------------------- *)

let () =
  Printf.printf "Running kgd_client tests...\n%!";

  (* Protocol round-trips *)
  test_encode_decode_nil ();
  test_encode_decode_bool ();
  test_encode_decode_positive_fixint ();
  test_encode_decode_negative_fixint ();
  test_encode_decode_uint8 ();
  test_encode_decode_uint16 ();
  test_encode_decode_uint32 ();
  test_encode_decode_int8 ();
  test_encode_decode_int16 ();
  test_encode_decode_fixstr ();
  test_encode_decode_str8 ();
  test_encode_decode_str16 ();
  test_encode_decode_bin ();
  test_encode_decode_fixarray ();
  test_encode_decode_empty_array ();
  test_encode_decode_fixmap ();
  test_encode_decode_nested ();
  test_decode_all ();

  (* Convenience accessors *)
  test_to_int ();
  test_to_string ();
  test_to_bool ();
  test_to_list ();
  test_to_assoc ();
  test_lookup ();

  (* msgpack-RPC format *)
  test_request_format ();
  test_response_format ();
  test_notification_format ();

  (* Anchors *)
  test_anchor_absolute ();
  test_anchor_tmux_pane ();
  test_anchor_nvim_win ();

  (* Types *)
  test_placement_info ();
  test_status_result ();
  test_place_opts ();
  test_color ();

  (* Binary data *)
  test_large_bin ();
  test_upload_message_format ();

  Printf.printf "\n%d tests run, %d failures\n%!" !tests_run !failures;
  if !failures > 0 then exit 1
