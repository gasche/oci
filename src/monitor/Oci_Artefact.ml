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
open Oci_Common

type conf = {
  storage : Oci_Filename.t;
  mutable next_id: Oci_Common.artefact;
  superroot : Oci_Common.user;
  (** A user outside the usernamespace so stronger than the root of
      the usernamespace *)
  root : Oci_Common.user;
  (** root in the usernamespace *)
  user: Oci_Common.user;
  (** A simple user in the usernamespace *)
} with sexp

type t = Oci_Common.artefact with sexp
let bin_t = Oci_Common.bin_artefact

exception Directory_should_not_exists of Oci_Filename.t

let dir_of_id conf id =
  let dir = Oci_Filename.mk (string_of_int id) in
  Oci_Filename.make_absolute conf.storage dir


let create conf src =
  let id = conf.next_id in
  conf.next_id <- conf.next_id + 1;
  let dst = dir_of_id conf id in
  Sys.file_exists_exn (Oci_Filename.get dst)
  >>= fun b ->
  if not b then raise (Directory_should_not_exists dst);
  Unix.mkdir (Oci_Filename.get dst)
  >>= fun () ->
  Async_shell.run "cp" ["-a";"--";
                        Oci_Filename.get src;
                        Oci_Filename.get dst]
  >>= fun () ->
  Async_shell.run "chown" ["-R";
                           Printf.sprintf "%i:%i"
                             conf.superroot.uid
                             conf.superroot.gid;
                           Oci_Filename.get dst]
  >>=
  fun () -> return id

let link_to conf id dst =
  let src = dir_of_id conf id in
  Async_shell.run "rm" ["-rf";"--";Oci_Filename.get dst]
  >>= fun () ->
  Async_shell.run "cp" ["-rla";"--";
                        Oci_Filename.get src;
                        Oci_Filename.get dst]

let copy_to conf id dst =
  let src = dir_of_id conf id in
  Async_shell.run "rm" ["-rf";"--";Oci_Filename.get dst]
  >>= fun () ->
  Async_shell.run "cp" ["-a";"--";
                        Oci_Filename.get src;
                        Oci_Filename.get dst]

let is_available conf id =
  let src = dir_of_id conf id in
  Sys.file_exists_exn (Oci_Filename.get src)