open Lwt
open Printf
open V1_LWT
open OS

let red fmt    = sprintf ("\027[31m"^^fmt^^"\027[m")
let green fmt  = sprintf ("\027[32m"^^fmt^^"\027[m")
let yellow fmt = sprintf ("\027[33m"^^fmt^^"\027[m")
let blue fmt   = sprintf ("\027[36m"^^fmt^^"\027[m")

(* Initialise timestamps, array and cid counters*)
let t0 = ref 0.0
let t1 = ref 0.0
let t_avg = ref 0.0
let i = ref 0
let j = ref 0
let delay_array = Array.make 64 0.0
let obj_count = ref 0
let oid = ref 0
let vm_name = ref ""
let t_start = ref 0.0
let irmin_task = "{\"task\":{\"date\":\"0\",\"uid\":\"0\",\"owner\":\"\",\"messages\":[\"write\"]},\"params\":\""
let avg_flag = ref false  (*flag to sum up consecutive avg values once the 16 array is full*)
let http_string = ref ""
let sum_avg_array = Array.make 16 0.0
let avg_array = Array.make 256 (0.0, 0.0)  (* For expermiental purposes *)
let avg_counter = ref 0
let exp_no = ref 0
let high_load = 0.000100 (* 100 micro seconds - High threshold value *)
let low_load = 150 (* average object request per second rate  - Low threshold value *)
let irmin_ip = (*"128.232.80.10"*) "10.0.0.1" (* Location of irmin store *)
let irmin_port = ref 0
let irmin_1 = ["12:43:3d:a3:d3:02"; "12:43:3d:a3:d3:03"; "12:43:3d:a3:d3:04"; "12:43:3d:a3:d3:05"; 
               "12:43:3d:a3:d3:06"; "12:43:3d:a3:d3:07"; "12:43:3d:a3:d3:08"; "12:43:3d:a3:d3:09";
               "c0:ff:ee:c0:ff:ee"; "12:43:3d:a3:d3:28"; 
               ]
let irmin_2 = ["12:43:3d:a3:d3:14"; "12:43:3d:a3:d3:15"; "12:43:3d:a3:d3:16"; "12:43:3d:a3:d3:17"; 
               "12:43:3d:a3:d3:18"; "12:43:3d:a3:d3:19"; "12:43:3d:a3:d3:1a"; "12:43:3d:a3:d3:1b";
               ]

module Main (C:CONSOLE) (FS:KV_RO) (S:STACKV4) (N0:NETWORK) = struct

  module H   = Cohttp_mirage.Server(Conduit_mirage.Flow)
  module HTTP = Cohttp_mirage.Client
   
  let conduit = Conduit_mirage.empty
  let stackv4 = Conduit_mirage.stackv4 (module S)
   
  (* Manual resolver for irmin ip and port *)  
  let irmin_store mac=
    let find_port = List.exists (fun x -> mac = x) irmin_1 in
    if find_port = true then (irmin_port := 8080 ) else (irmin_port := 8081); 
    let hosts = Hashtbl.create 3 in
    Hashtbl.add hosts "irmin"     
      (fun ~port -> `TCP (Ipaddr.of_string_exn irmin_ip, !irmin_port));
    hosts
      
  (* Send request/posts to Irmin *)     
  let http_post c ctx req uri =    
    (*C.log_s c (sprintf "Posting in path %s" (Uri.to_string uri)) >>= fun () ->*)
    HTTP.post ~ctx ~body:req uri >>= fun (resp, body) ->
    Cohttp_lwt_body.to_string req >>= fun body -> 
    C.log_s c (sprintf ("Posting:%s in path %s") body (Uri.to_string uri))

  let http_get c ctx uri =
    C.log_s c (sprintf "Fetching %s:" (Uri.to_string uri)) >>= fun () ->
    HTTP.get ~ctx uri >>= fun (response, body) ->
    Cohttp_lwt_body.to_string body >>= fun body ->
      let _ = C.log_s c (sprintf "Response: %s" (body)) in
      let str = Re_str.replace_first (Re_str.regexp ".*\\[") "" body in
      let str_value = Re_str.replace_first (Re_str.regexp "\\].*") "" str in
      C.log_s c (sprintf "Value: %s" (str_value)) >>= fun () -> Lwt.return(str_value)
 
  (* Conduit connection helper *)
  let conduit_conn c stack req uri=
    Lwt.ignore_result (
      lwt conduit = Conduit_mirage.with_tcp Conduit_mirage.empty stackv4 stack in
      let res = Resolver_mirage.static (irmin_store !vm_name) in
      let ctx = HTTP.ctx res conduit in
      http_post c ctx req uri)

  (* To be replaced *)      
  let conduit_get c stack uri=
    lwt conduit = Conduit_mirage.with_tcp Conduit_mirage.empty stackv4 stack in
    let res = Resolver_mirage.static (irmin_store !vm_name) in
    let ctx = HTTP.ctx res conduit in
    http_get c ctx uri
     
  (* Monitor-Scale up based on request/reply times *)
  let scale_up c stack =
    Lwt.return (
      t1 := Time.Monotonic.to_seconds(Time.Monotonic.time());
      let delay = !t1 -. !t0 in  (* response time for each http object served *)
      delay_array.(!i) <- delay;
      (*C.log c (sprintf "delay = %f" delay);*) (* For debugging *)
      if !i < (Array.length delay_array - 1)
        then incr i
        else (
          i := 0;
          let avg =
            (Array.fold_right (+.) delay_array 0.0) /. float(Array.length delay_array) in  (* Avg over 64 values *)
            sum_avg_array.(!j) <- avg;
          if !j < (Array.length sum_avg_array - 1)  (* compute sum avg if array has benn filled up *)
          then (
            incr j; )
          else (
            j:= 0;
            avg_flag := true );
          if !avg_flag then (
            let sum_avg =
              (Array.fold_right (+.) sum_avg_array 0.0) /. float(Array.length sum_avg_array) in (* Sum Avg of 16 values of 64 avgs *)
              t_avg := Clock.time();  (* part of experiment *)
              C.log c (sprintf "Avg delay = %f" sum_avg);
              if sum_avg >= high_load then (
              let rpc_add = Rpc.Enum [
                  Rpc.rpc_of_string "add";
                  Rpc.rpc_of_string !vm_name;
                  Rpc.rpc_of_string "static-web";
                ] in
              let add = Rpc.to_string rpc_add in
              let add_vm = `String (irmin_task ^ add ^ "\"}") in
              let uri = (Uri.of_string ("http://irmin:8080/update/jitsu/request/" ^ !vm_name ^ "/action")) in
              conduit_conn c stack add_vm uri;
              C.log c (sprintf "CREATE REPLICA........");
              (*C.log c (sprintf "Posting in path %s" (Uri.to_string uri));*)
            );
          (* Experiment - Post latency values *)
          let avg_tuple = (!t_avg,sum_avg) in
          avg_array.(!avg_counter) <- avg_tuple;
          if !avg_counter < (Array.length avg_array - 1)
          then incr avg_counter
          else (
            avg_counter := 0;
            incr exp_no;
            C.log c (sprintf "***  RPC STRING COMPLETED %d  ***" !exp_no);
            let rpc_avg_array = Rpc.Enum [
                Rpc.rpc_of_string (Array.fold_right (fun (x, y) acc ->
                    (string_of_float x)^" "^(sprintf "%f" y)^";"^acc ) avg_array "")
              ] in
            let rpc_avg_string = Rpc.to_string rpc_avg_array in
            let avg_rpc = `String (irmin_task ^ rpc_avg_string ^ "\"}") in
            let uri = (Uri.of_string ("http://irmin:8080/update/jitsu/exp/" ^ !vm_name ^ "/data" ^ (string_of_int !exp_no))) in
            conduit_conn c stack avg_rpc uri; )
           )
         )
       )
        
  (* Monitor-Scale down based on objects requested *)
  let rec scale_down c stack n =                                                      
    oid := !obj_count;
    Time.sleep n >>= fun () ->
    let avg_objreq = (!obj_count - !oid)/5 in
    if avg_objreq < low_load then (
      let rpc_del = Rpc.Enum [
          Rpc.rpc_of_string "delete";
          Rpc.rpc_of_string !vm_name;
         ] in
      let del = Rpc.to_string rpc_del in
      let delete_vm = `String (irmin_task ^ del ^ "\"}") in
      let uri = (Uri.of_string ("http://irmin/update/jitsu/request/" ^ !vm_name ^ "/action")) in
      conduit_conn c stack delete_vm uri;
      C.log c (sprintf "LOW LOAD -> delete replica")  (* For debugging *)
    );
    (*else C.log c (sprintf "Objects requested in last 5s: %d" (!obj_count - !oid));*) (* For debugging *)
    C.log c (sprintf "avg objects/sec: %d" avg_objreq);
    scale_down c stack n

  (* START *)
  let start c fs stack n0 =
    let _ = vm_name := Macaddr.to_string (N0.mac n0) in
    let uri = (Uri.of_string ("http://irmin/read/jitsu/" ^ !vm_name ^ "/initial_xs")) in
    lwt initial_xs = (conduit_get c stack uri) in
    let _ = C.log_s c (sprintf "Initial XS: %s" (initial_xs)) in
    Lwt.join[(
        let read_fs name =
          FS.size fs name >>= function
          | `Error (FS.Unknown_key _) -> fail (Failure ("read " ^ name))
          | `Ok size ->
            FS.read fs name 0 (Int64.to_int size) >>= function
            | `Error (FS.Unknown_key _) -> fail (Failure ("read " ^ name))
            | `Ok bufs -> return (Cstruct.copyv bufs)
        in

        (* Split a URI into a list of path segments *)
        let split_path uri =
          let path = Uri.path uri in
          let rec aux = function
            | [] | [""] -> []
            | hd::tl -> hd :: aux tl
          in
          List.filter (fun e -> e <> "")
            (aux (Re_str.(split_delim (regexp_string "/") path)))
        in

        (* dispatch non-file URLs *)
        let rec dispatcher = function
          | [] | [""] -> dispatcher ["index.html"]
          | segments -> 
            let path = String.concat "/" segments in 
            Lwt.catch (fun () -> 
                read_fs path >>= fun body ->
                incr obj_count;
                H.respond_string ~status:`OK ~body ()
              )  (fun exn ->
                H.respond_not_found ()
              )
        in
        (* HTTP callback *)
        let callback conn_id request body =
          t0 := Time.Monotonic.to_seconds(Time.Monotonic.time());
          let uri = Cohttp.Request.uri request in
          let reply = dispatcher (split_path uri) in
          let _ = scale_up c stack in (* response time per object *)
          reply
        in
        let conn_closed (_,conn_id) =
          let cid = Cohttp.Connection.to_string conn_id  in
          (*C.log c (sprintf "conn %s closed" cid); (* For debugging *) *)
          () in
        Conduit_mirage.with_tcp conduit stackv4 stack >>= fun conduit ->
        let spec = H.make ~conn_closed ~callback:callback () in
        Conduit_mirage.listen conduit (`TCP 80) (H.listen spec));
        (scale_down c stack 5.0);] (* Scale down monitor thread *)

end
