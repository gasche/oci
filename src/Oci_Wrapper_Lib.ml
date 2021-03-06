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

(** execute a program in a new usernamespace *)

(** We can't use Async since we must play with forks and async doesn't
    like that *)
open Core.Std
open ExtUnix.Specific

let mkdir ?(perm=0o750) dir =
  if not (Sys.file_exists_exn dir) then Unix.mkdir dir ~perm

let mount_inside ~dir ~src ~tgt ?(fstype="") ~flags ?(option="") () =
  let tgt = Filename.concat dir tgt in
  mkdir tgt;
  mount ~source:src ~target:tgt ~fstype flags ~data:option

let mount_base dir =
(*
  mount ~source:dir ~target:dir ~fstype:"" [MS_BIND;MS_PRIVATE;MS_REC] ~data:"";
*)
  mount_inside ~dir ~src:"proc" ~tgt:"proc" ~fstype:"proc"
    ~flags:[MS_NOSUID; MS_NOEXEC; MS_NODEV] ();
  mount_inside ~dir ~src:"/sys" ~tgt:"sys" ~flags:[MS_BIND; MS_REC] ();

  mount_inside ~dir ~src:"tmpfs" ~tgt:"dev" ~fstype:"tmpfs"
    ~flags:[MS_NOSUID; MS_STRICTATIME]
    ~option:"mode=755,uid=0,gid=0" ();

  mount_inside ~dir ~src:"devpts" ~tgt:"dev/pts" ~fstype:"devpts"
    ~flags:[MS_NOSUID;MS_NOEXEC]
    ~option:"newinstance,ptmxmode=0666,mode=0620,gid=5" ();

  mount_inside ~dir ~src:"tmpfs" ~tgt:"dev/shm" ~fstype:"tmpfs"
    ~flags:[MS_NOSUID; MS_STRICTATIME; MS_NODEV]
    ~option:"mode=1777,uid=0,gid=0" ();

  List.iter ~f:(fun (src,dst) ->
      Unix.symlink ~src ~dst:(Filename.concat dir dst))
  [ "/proc/kcore", "/dev/core";
    "/proc/self/fd", "/dev/fd";
    "/proc/self/fd/0", "/dev/stdin";
    "/proc/self/fd/1", "/dev/stdout";
    "/proc/self/fd/2", "/dev/stderr";
    "/dev/pts/ptmx", "/dev/ptmx";
  ];

  List.iter ~f:(fun src ->
      let dst = Filename.concat dir src in
      let fd =
        Unix.openfile ~perm:0o644 ~mode:[O_WRONLY;O_CREAT;O_CLOEXEC]
          dst
      in
      mount ~source:src ~target:dst ~fstype:"" ~data:"" [MS_BIND];
      Unix.close fd;
    )
  [ "/dev/console";
    "/dev/tty";
    "/dev/full";
    "/dev/null";
    "/dev/zero";
    "/dev/random";
    "/dev/urandom";
  ];

  mount_inside ~dir ~src:"tmpfs" ~tgt:"run" ~fstype:"tmpfs"
    ~flags:[MS_NOSUID; MS_STRICTATIME; MS_NODEV]
    ~option:"mode=755,uid=0,gid=0" ();

  (* for aptitude *)
  mkdir (Filename.concat dir "/run/lock")

let do_chroot dest =
  Sys.chdir dest;
  chroot ".";
  Sys.chdir "/"

let read_in_file fmt =
  Printf.ksprintf (fun file ->
      let c = open_in file in
      let v = input_line c in
      In_channel.close c;
      v
    ) fmt


let test_userns_availability () =
  let unpriviledge_userns_clone =
    "/proc/sys/kernel/unprivileged_userns_clone" in
  if Sys.file_exists_exn unpriviledge_userns_clone then begin
    let v = read_in_file "%s" unpriviledge_userns_clone in
    if v <> "1" then begin
      Printf.eprintf "This kernel is configured to disable unpriviledge user\
                      namespace: %s must be 1\n" unpriviledge_userns_clone;
      exit 1
    end
  end

let write_in_file fmt =
  Printf.ksprintf (fun file ->
      Printf.ksprintf (fun towrite ->
          try
            let cout = open_out file in
            output_string cout towrite;
            Out_channel.close cout
          with _ ->
            Printf.eprintf "Error during write of %s in %s\n"
              towrite file;
            exit 1
        )
    ) fmt

let command fmt = Printf.ksprintf (fun cmd -> Sys.command cmd = 0) fmt

let command_no_fail ?(error=(fun () -> ())) fmt =
  Printf.ksprintf (fun cmd ->
      let c = Sys.command cmd in
      if c <> 0 then begin
        Printf.eprintf "Error during: %s\n%!" cmd;
        error ();
        exit 1;
      end
    ) fmt

(** {2 CGroup} *)
let move_to_cgroup name =
  command_no_fail
    "cgm movepid all %s %i" name (Pid.to_int (Unix.getpid ()))

let set_cpuset cgroupname cpuset =
  command_no_fail
    "cgm setvalue cpuset %s cpuset.cpus %s"
    cgroupname
    (String.concat ~sep:"," (List.map ~f:Int.to_string cpuset))

(** {2 User namespace} *)
open Oci_Wrapper_Api

let set_usermap idmaps pid =
  assert (idmaps <> []);
  let call cmd proj =
    (* newuidmap pid uid loweruid count [uid loweruid count [ ... ]] *)
    let argv = List.fold_left ~f:(fun acc idmap ->
        idmap.length_id::(proj idmap.extern_id)::(proj idmap.intern_id)::acc
      ) ~init:[Pid.to_int pid] idmaps in
    let argv = List.rev_map ~f:string_of_int argv in
    Core_extended.Shell.run ~expect:[0] cmd argv in
  call "newuidmap" (fun u -> u.uid);
  call "newgidmap" (fun u -> u.gid)

let do_as_the_child_on_error pid =
  match Unix.waitpid pid with
  | Ok () -> ()
  | Error (`Exit_non_zero i) -> exit i
  | Error (`Signal s) ->
    Signal.send_i s (`Pid (Unix.getpid ())); assert false

let goto_child ~exec_in_parent =
  let fin,fout = Unix.pipe () in
  match Unix.fork () with
  | `In_the_child -> (* child *)
    Unix.close fout;
    ignore (Unix.read fin ~buf:(Bytes.create 1) ~pos:0 ~len:1);
    Unix.close fin
  | `In_the_parent pid ->
    (* execute the command and wait *)
    Unix.close fin;
    (exec_in_parent pid: unit);
    ignore (Unix.write fout ~buf:(Bytes.create 1) ~pos:0 ~len:1);
    Unix.close fout;
    do_as_the_child_on_error pid;
    exit 0

let exec_in_child (type a) f =
  let fin,fout = Unix.pipe () in
  match Unix.fork () with
  | `In_the_child -> (* child *)
    Unix.close fout;
    let cin = Unix.in_channel_of_descr fin in
    let arg = (Marshal.from_channel cin : a) in
    In_channel.close cin;
    f arg;
    exit 0
  | `In_the_parent pid ->
    Unix.close fin;
    let cout = Unix.out_channel_of_descr fout in
    let call_in_child (arg:a) =
      Marshal.to_channel cout arg [];
      Out_channel.close cout;
      do_as_the_child_on_error pid
    in
    call_in_child

let exec_now_in_child f arg =
  match Unix.fork () with
  | `In_the_child -> (* child *)
    f arg;
    exit 0
  | `In_the_parent pid ->
    do_as_the_child_on_error pid

let just_goto_child () =
  match Unix.fork () with
  | `In_the_child -> (* child *) ()
  | `In_the_parent pid ->
    do_as_the_child_on_error pid;
    exit 0


let go_in_userns ?(send_pid=(fun _ -> ())) idmaps =
  (* the usermap can be set only completely outside the namespace, so we
      keep a child for doing that when we have a pid completely inside the
      namespace *)
  let call_set_usermap = exec_in_child (set_usermap idmaps) in
  unshare [ CLONE_NEWNS;
            CLONE_NEWIPC;
            CLONE_NEWPID;
            CLONE_NEWUTS;
            CLONE_NEWUSER;
          ];
  (* only the child will be in the new pid namespace, the parent is in an
      intermediary state not interesting *)
  goto_child ~exec_in_parent:(fun pid ->
      send_pid pid;
      call_set_usermap pid)
  (* Printf.printf "User: %i (%i)\n%!" (Unix.getuid ()) (Unix.geteuid ()); *)
  (* Printf.printf "Pid: %i\n%!" (Unix.getpid ()); *)
  (* Printf.printf "User: %i (%i)\n%!" (Unix.getuid ()) (Unix.geteuid ()); *)

let test_overlay () =
  (* for test *)
  let test = "/overlay" in
  let ro = Filename.concat test "ro" in
  let rw = Filename.concat test "rw" in
  let wd = Filename.concat test "wd" in
  let ov = Filename.concat test "ov" in
  mkdir test; mkdir ro; mkdir rw; mkdir wd; mkdir ov;
  mount ~source:"overlay" ~target:ov ~fstype:"overlay"
  []
  ~data:(Printf.sprintf "lowerdir=%s,upperdir=%s,workdir=%s" ro rw wd)

