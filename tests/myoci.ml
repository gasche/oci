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

module MasterInt = Oci_Master.Make(Int)(Int)

let () =
  MasterInt.create_master_and_runner
    Test_succ.test_succ
    ~error:(fun _ -> Int.min_value)
    ~binary_name:"test_succ_runner"
    (Oci_Master.dispatch_exn Test_succ.test_succ)


let () =
  MasterInt.create_master_and_runner
    Test_succ.test_fibo
    ~error:(fun _ -> Int.min_value)
    ~binary_name:"test_succ_runner"
    (Oci_Master.dispatch_exn Test_succ.test_fibo)

let () =
  MasterInt.create_master_and_runner
    Test_succ.test_fibo_artefact
    ~error:(fun _ -> Int.min_value)
    ~binary_name:"test_succ_runner"
    (Oci_Master.dispatch_exn Test_succ.test_fibo_artefact)

let () =
  MasterInt.create_master_and_runner
    Test_succ.test_fibo_error_artefact
    ~error:(fun _ -> Int.min_value)
    ~binary_name:"test_succ_runner"
    (Oci_Master.dispatch_exn Test_succ.test_fibo_error_artefact)

module MasterIntArtefact = Oci_Master.Make(Int)(Oci_Common.Artefact)

let () =
  MasterIntArtefact.create_master_and_runner
    Test_succ.test_fibo_artefact_aux
    ~error:(fun _ -> raise Exit)
    ~binary_name:"test_succ_runner"
    (Oci_Master.dispatch_exn Test_succ.test_fibo_artefact_aux)

let () = never_returns (Oci_Master.run ())