(* This file is part of Bisect_ppx, released under the MIT license. See
   LICENSE.md for details, or visit
   https://github.com/aantron/bisect_ppx/blob/master/LICENSE.md. *)



(** This module defines utility functions for the report program. *)



val verbose : bool ref
val info : ('a, unit, string, unit) format4 -> 'a
val error : ('a, unit, string, 'b) format4 -> 'a

val elementwise_saturation_addition : int array -> int array -> int array
(** Returns the sum of the passed arrays, using saturation arithmetic to sum
    elements. The length of the returned array is the maximum of the lengths of
    the passed arrays, missing elements from the smallest array being supposed
    to be equal to [0]. *)

val mkdirs : ?perm:Unix.file_perm -> string -> unit
(** Creates the directory whose path is passed, and all necessary parent
    directories. The optional [perms] parameter indicates the permissions
    used for directory creation(s), defaulting to [0o755].

    Raises [Unix.Unix_error] if creation fails. *)

val split : ('a -> bool) -> ('a list) -> 'a list * 'a list
(** [split p [e1; ...; en]] returns [([e1; ...; e(i-1)], [ei; ...; en])]
    where [i] is the lowest index such that [p ei] evaluates to false. *)

val open_both : string -> string -> in_channel * out_channel
(** [open_both in_file out_file] return a [(i, o)] couple where:
    - [i] is an input channel for [in_file];
    - [o] is an output channel for [out_file].

    Raises an exception if an error occurs; ensures that files are either
    both opened or both closed. *)

(** Types and functions related to visitation counts.
    All operations gracefully handle overflows by ensuring that:
    - a value above [max_int] is encoded by [max_int];
    - a value below [min_int] is encoded by [min_int]. *)

type counts = {
    mutable visited : int; (** Number of points actually visited. *)
    mutable total : int (** Total number of points. *)
  }
(** The type of visitation count statistics. These are used for each file, and
    for the whole project. *)

val make : unit -> counts
(** Evaluates to [{visited = 0; total = 0}]. *)

val update : counts -> bool -> unit
(** [update counts v] updates [counts]. [counts.total] is always incremented,
    while [counts.visited] is incremented iff [v] equals [true]. *)

val add : counts -> counts -> counts
(** [add x y] returns the sum of counts [x] and [y]. *)

val line_counts :
  'a -> string -> int array -> ('a, int list) Hashtbl.t -> int option list
(** [line_counts verbose in_file resolved_in_file visited points] computes the
    visited lines for [in_file]. *)

val search_file : string list -> bool -> string -> string option