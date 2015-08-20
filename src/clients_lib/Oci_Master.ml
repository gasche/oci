(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2013                                                    *)
(*    CEA (Commissariat à l'énergie atomique et aux énergies              *)
(*         alternatives)                                                  *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Core.Std
open Async.Std

let oci_at_shutdown = Oci_Artefact_Api.oci_at_shutdown

type runner_result = Oci_Artefact_Api.exec_in_namespace_response =
  | Exec_Ok
  | Exec_Error of string with bin_io

let register data f = Oci_Artefact.register_master data f
let register_saver = Oci_Artefact.register_saver
let run () = Oci_Artefact.run ()
let start_runner ~binary_name = Oci_Artefact.start_runner ~binary_name
let stop_runner conn =
  Rpc.Rpc.dispatch_exn Oci_Artefact_Api.rpc_stop_runner conn ()
let permanent_directory = Oci_Artefact.permanent_directory

module Make(Query : Hashtbl.Key_binable) (Result : Binable.S) = struct
  module H = Hashtbl.Make(Query)

  type save_data = (Query.t * Result.t) list with bin_io

  let create_master data f =
    let db : ('result Deferred.t) H.t = H.create () in
    let f q =
      match H.find db q with
      | Some r -> r
      | None ->
        let ivar = Ivar.create () in
        let ivar_d = Ivar.read ivar in
        H.add_exn db ~key:q ~data:ivar_d;
        begin
          f q
          >>> fun r ->
          Ivar.fill ivar r
        end;
        ivar_d
    in
    register_saver
      ~loader:(fun () ->
          permanent_directory data
          >>= fun dir ->
          let file = Oci_Filename.make_absolute dir "data" in
          Sys.file_exists_exn file
          >>= fun exi ->
          begin if exi then begin
              Reader.open_file file
              >>= fun reader ->
              Reader.read_bin_prot reader bin_reader_save_data
              >>= function
              | `Eof -> return ()
              | `Ok r ->
                List.iter
                  ~f:(fun (q,r) -> H.add_exn db ~key:q ~data:(return r))
                  r;
                return ()
            end
            else return ()
          end
        )
      ~saver:(fun () ->
          let l = H.fold ~init:[]
              ~f:(fun ~key ~data acc ->
                  if Deferred.is_determined data
                  then (data >>= fun data -> return (key,data))::acc
                  else acc
                ) db in
          Deferred.all l
          >>= fun l ->
          permanent_directory data
          >>= fun dir ->
          let file = Oci_Filename.make_absolute dir "data" in
          let file_bak = Oci_Filename.add_extension file "bak" in
          Sys.file_exists_exn file
          >>= fun exi ->
          begin if exi then begin
              Oci_Std.unlink_no_fail file_bak
              >>= fun () ->
              Unix.rename ~src:file ~dst:file_bak
            end
            else return ()
          end
          >>= fun () ->
          Writer.open_file file
          >>= fun writer ->
          Writer.write_bin_prot writer bin_writer_save_data l;
          Writer.close writer
        );
    register data f

  let create_master_and_runner data ?(binary_name=Oci_Data.name data) ~error f =
    create_master data
      begin fun q ->
        start_runner ~binary_name
        >>= fun (err,conn) ->
        choose [
          choice (err >>= function
            | Exec_Ok -> never ()
            | Exec_Error s -> return s) error;
          choice begin
            conn >>= fun conn ->
            Shutdown.at_shutdown (fun () -> Rpc.Connection.close conn);
            f conn q
            >>= fun res ->
            stop_runner conn
            >>= fun () ->
            Rpc.Connection.close conn;
            >>= fun () ->
            return res
          end (fun x -> x);
        ]
      end


end

