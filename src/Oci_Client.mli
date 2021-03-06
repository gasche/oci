(**************************************************************************)
(*                                                                        *)
(*  This file is part of OCI.                                             *)
(*                                                                        *)
(*  Copyright (C) 2015-2016                                               *)
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

module Git: sig
  type formatted_proc

  val formatted_proc : (int -> string, unit, string) format -> formatted_proc

  type env = [ `Extend of (string * string) list
             | `Replace of (string * string) list ]

  type args = [ `Proc of formatted_proc | `S of string ]

  val mk_proc: (int -> string, unit, string) format -> args

  type exec = {
    cmd: string;
    args: [ `S of string | `Proc of formatted_proc ] list;
    env : [ `Replace of (string * string) list
          | `Extend of (string * string) list];
    proc_requested : int;
    working_dir: Oci_Filename.t (** Relative path *);
    timelimit: Time.Span.t option;
    memlimit: Byte_units.t option;
  }
  type gitclone type gitcopyfile type copyfile
  type cmd = [
    | `Exec of exec
    | `GitClone of gitclone
    | `GitCopyFile of gitcopyfile
    | `CopyFile of copyfile
  ]

  val exec:
    ?args:args list ->
    ?env:env ->
    ?proc_requested:int ->
    ?working_dir:Oci_Filename.filename ->
    ?timelimit:Time.Span.t ->
    ?memlimit:Byte_units.t ->
    string -> [> `Exec of exec ]

  val run:
    ?env:env ->
    ?proc_requested:int ->
    ?working_dir:Oci_Filename.filename ->
    ?timelimit:Time.Span.t ->
    ?memlimit:Byte_units.t ->
    string -> string list -> [> `Exec of exec ]

  val make:
    ?j:int ->
    ?vars:(string * string) list ->
    ?working_dir:Oci_Filename.filename ->
    ?env :env ->
    ?timelimit:Time.Span.t ->
    ?memlimit:Byte_units.t ->
    string list ->
    [> `Exec of exec ]

  val git_clone:
    url:string ->
    ?dir:Oci_Filename.t ->
    Commit.t ->
    cmd

  val git_copy_file:
    url:string ->
    src:Oci_Filename.t ->
    dst:Oci_Filename.t ->
    Commit.t ->
    cmd

  val copy_file:
    checksum:string ->
    kind:[`MD5] ->
    Oci_Filename.t ->
    cmd

  type repo

  val repo:
    ?save_artefact:bool ->
    ?deps:Core.Std.String.t list ->
    ?cmds:cmd list ->
    ?tests:cmd list ->
    unit ->
    repo

  type t

  val used_repos: t -> repo String.Map.t
  val filter_deps_for: t -> t
  val invariant: t -> bool
  val repos:
    name:string ->
    repos:repo String.Map.t ->
    rootfs:Oci_Rootfs_Api.Rootfs.t ->
    t

  type connection
  val socket_of_connection:
    connection -> Async_extra.Import.Rpc_kernel.Connection.t

  type compile_and_tests =
    [ `Artefact of Artefact.t
    | `Cmd of exec * Unix.Exit_or_signal.t * Timed.t
    | `Dependency_error of Core.Std.String.Set.t ]

  val pp: Format.formatter -> compile_and_tests -> unit

  val compile_and_tests:
    connection -> t ->
    (compile_and_tests Oci_Log.line Async_kernel.Std.Pipe.Reader.t)
      Async_kernel.Std.Deferred.t

  type xpra = [compile_and_tests | `XpraDir of Oci_Filename.t ]

  val pp_xpra: Format.formatter -> xpra -> unit

  val xpra:
    connection -> t ->
    (xpra Oci_Log.line Async_kernel.Std.Pipe.Reader.t)
      Async_kernel.Std.Deferred.t

  val merge_base:
    connection ->
    url:string ->
    Commit.t -> Commit.t ->
    Commit.t Deferred.t

  val commit_of_revspec:
    connection ->
    url:string ->
    revspec:string ->
    Commit.t option Deferred.t

  val commit_of_branch:
    connection ->
    url:string ->
    branch:string ->
    Commit.t option Deferred.t

  val last_commit_before:
    connection ->
    url:string ->
    branch:string ->
    time:Time.t ->
    Commit.t option Deferred.t

  val time_of_commit:
    connection ->
    url:string ->
    commit:Commit.t ->
    Time.t Deferred.t

  val download_file:
    connection ->
    kind:[`MD5] ->
    url:string ->
    checksum:string ->
    unit Deferred.t
end

module Cmdline: sig

  module WP: sig
    type 'a param
    module ParamValue: sig
      type t [@@deriving sexp]
      val mem : t -> 'a param -> bool
      val find : t -> 'a param -> 'a option
      val find_def : t -> 'a param -> 'a
      val set : t -> 'a param -> 'a -> t
      val replace_by: t -> t -> t
    end
    type 'a with_param


    val const: 'a -> 'a with_param
    val ( !! ): 'a -> 'a with_param

    val ( $ ): ('a -> 'b) with_param -> 'a with_param -> 'b with_param

    val param: 'a param -> 'a with_param
    val ( !? ): 'a param -> 'a with_param
    val ( $? ): ('a -> 'b) with_param -> 'a param -> 'b with_param

    val connection: Git.connection with_param

    val print: ('a -> string Async.Std.Deferred.t) -> 'a with_param
      -> 'a with_param

    val mk_param :
      default:'a ->
      ?sexp_of:('a -> Sexplib.Sexp.t) ->
      ?of_sexp:(Async.Std.Sexp.t -> 'a) ->
      ?cmdliner:'a Core.Std.Univ_map.data Core.Std.Univ_map.data
        Cmdliner.Term.t ->
      'b Core.Std.String.Table.key_ -> 'a param

  end

  type repo_param = Git.repo Deferred.t WP.with_param
  type repo = string

  val mk_repo:
    ?revspec:string ->
    url:string ->
    deps:repo list ->
    cmds:Git.cmd list ->
    ?tests:Git.cmd list ->
    string (* name *) -> repo * string WP.param

  val mk_copy_file:
    url:string list ->
    checksum:string ->
    kind:[`MD5] ->
    Oci_Filename.t ->
    Git.cmd

  type query = Oci_Generic_Masters_Api.CompileGitRepo.Query.t

  val cmdliner_revspecs: WP.ParamValue.t -> (WP.ParamValue.t Cmdliner.Term.t)

  type ('x,'y) compare =
    Git.connection ->
    WP.ParamValue.t -> 'x -> 'y ->
    (WP.ParamValue.t * repo_param * [`Exec of Git.exec ]) Deferred.t

  val mk_compare:
    deps:repo List.t ->
    cmds:(Git.connection ->
          WP.ParamValue.t ->
          'x -> 'y ->
          (WP.ParamValue.t * Git.cmd list * [ `Exec of Git.exec ]) Deferred.t)
    ->
    x_of_sexp:(Sexp.t -> 'x) ->
    sexp_of_x:('x -> Sexp.t) ->
    y_of_sexp:(Sexp.t -> 'y) ->
    sexp_of_y:('y -> Sexp.t) ->
    analyse:(Unix.Exit_or_signal.t ->
             Oci_Common.Timed.t -> float option) ->
    string ->
    unit
    (** The time of the last command is used *)

  module Predefined: sig
    val ocaml: repo
    val ocamlfind: repo
    val zarith: repo
    val xmllight: repo
    val camlp4: repo
    val lablgtk: repo
    val ocamlgraph: repo
    val cppo: repo
    val camomile: repo
    val ounit: repo
    val cryptokit: repo
    val ocamlbuild: repo
  end

  type create_query_hook =
    connection:Git.connection ->
    root:repo -> revspecs:WP.ParamValue.t ->
    (repo * WP.ParamValue.t) Deferred.t

  type cmds_without_connection =
    [ `Error | `Ok ] Async.Std.Deferred.t Cmdliner.Term.t *
    Cmdliner.Term.info

  type cmds_with_connection =
    (Git.connection ->
     [ `Error | `Ok ] Async.Std.Deferred.t) Cmdliner.Term.t *
    Cmdliner.Term.info


  val default_cmdline:
    ?create_query_hook:create_query_hook Cmdliner.Term.t (* experts only *) ->
    ?cmds_without_connections:cmds_without_connection list ->
    ?cmds_with_connections:cmds_with_connection list ->
    ?doc:string ->  ?version:string ->
    string -> unit Deferred.t
  (** parse cmdline, run, and quit *)

  (** {2 Experts only} *)
  val add_repo: string -> Git.repo -> unit
  val add_repo_with_param: string -> repo_param -> unit
  val exec:
    ?init:([> `Ok ] as 'c) ->
    ?fold:
      ('c ->
       [> `Error of Core_kernel.Error.t | `Incomplete | `Ok of 'b ] -> 'c) ->
    ('a, 'b) Oci_Data.t ->
    'a ->
    ('a -> Sexplib.Type.t) ->
    (Format.formatter -> 'b -> unit) ->
    Git.connection -> 'c Async_kernel.Types.Deferred.t
  val mk_commit_param:
    url:string ->
    string ->
    Core.Std.String.t WP.param ->
    Oci_Common.Commit.t Async.Std.Deferred.t WP.with_param
  val mk_revspec_param:
    ?revspec:Core.Std.String.t ->
    'a Core.Std.String.Table.key_ -> Core.Std.String.t WP.param

end


val oci_version: string
