(* This file is part of Bisect_ppx, released under the MIT license. See
   LICENSE.md for details, or visit
   https://github.com/aantron/bisect_ppx/blob/master/LICENSE.md. *)



module Coverage_input_files :
sig
  val list : string list -> string list -> string list
  val expected_sources_are_present :
    string list -> string list -> string list -> unit
end =
struct
  let has_extension extension filename =
    Filename.check_suffix filename extension

  let list_recursively directory filename_filter =
    let rec traverse directory files =
      Sys.readdir directory
      |> Array.fold_left begin fun files entry ->
        let entry_path = Filename.concat directory entry in
        match Sys.is_directory entry_path with
        | true ->
          traverse entry_path files
        | false ->
          if filename_filter entry_path entry then
            entry_path::files
          else
            files
        | exception Sys_error _ ->
          files
      end files
    in
    traverse directory []

  let filename_filter _path filename =
    has_extension ".coverage" filename

  let list files_on_command_line coverage_search_paths =
    (* If there are files on the command line, or coverage search directories
       specified, use those. Otherwise, search for files in ./ and ./_build.
       During the search, we look for files with extension .coverage. *)
    let all_coverage_files =
      match files_on_command_line, coverage_search_paths with
      | [], [] ->
        let in_current_directory =
          Sys.readdir Filename.current_dir_name
          |> Array.to_list
          |> List.filter (fun entry ->
            filename_filter (Filename.(concat current_dir_name) entry) entry)
        in
        let in_build_directory =
          if Sys.file_exists "_build" && Sys.is_directory "_build" then
            list_recursively "./_build" filename_filter
          else
            []
        in
        let in_esy_sandbox =
          match Sys.getenv "cur__target_dir" with
          | exception Not_found -> []
          | directory ->
            if Sys.file_exists directory && Sys.is_directory directory then
              list_recursively directory filename_filter
            else
              []
        in
        in_current_directory @ in_build_directory @ in_esy_sandbox

      | _ ->
        coverage_search_paths
        |> List.filter Sys.file_exists
        |> List.filter Sys.is_directory
        |> List.map (fun dir -> list_recursively dir filename_filter)
        |> List.flatten
        |> (@) files_on_command_line
    in

    begin
      match files_on_command_line, coverage_search_paths with
    | [], [] | _, _::_ ->
      (* Display feedback about where coverage files were found. *)
      all_coverage_files
      |> List.map Filename.dirname
      |> List.sort_uniq String.compare
      |> List.map (fun directory -> directory ^ Filename.dir_sep)
      |> List.iter (Util.info "found coverage files in '%s'")
    | _ ->
      ()
    end;

    if all_coverage_files = [] then
      Util.error "no coverage files given on command line or found"
    else
      all_coverage_files

  let strip_extensions filename =
    let dirname, basename = Filename.(dirname filename, basename filename) in
    let basename =
      match String.index basename '.' with
      | index -> String.sub basename 0 index
      | exception Not_found -> basename
    in
    Filename.concat dirname basename

  let list_expected_files paths =
    paths
    |> List.map (fun path ->
      if Filename.(check_suffix path dir_sep) then
        list_recursively path (fun _path filename ->
          [".ml"; ".re"; ".mll"; ".mly"]
          |> List.exists (Filename.check_suffix filename))
      else
        [path])
    |> List.flatten
    |> List.sort_uniq String.compare

  let filtered_expected_files expect do_not_expect =
    let expected_files = list_expected_files expect in
    let excluded_files = list_expected_files do_not_expect in
    expected_files
    |> List.filter (fun path -> not (List.mem path excluded_files))
    (* Not the fastest way. *)

  let expected_sources_are_present present_files expect do_not_expect =
    let present_files = List.map strip_extensions present_files in
    let expected_files = filtered_expected_files expect do_not_expect in
    expected_files |> List.iter (fun file ->
      if not (List.mem (strip_extensions file) present_files) then
        Util.error "expected file '%s' is not included in the report" file)
end

let try_finally x f h =
  let res =
    try
      f x
    with e ->
      (try h x with _ -> ());
      raise e in
  (try h x with _ -> ());
  res

let try_in_channel bin x f =
  let open_ch = if bin then open_in_bin else open_in in
  try_finally (open_ch x) f (close_in_noerr)

(* filename + reason *)
exception Invalid_file of string * string

module Reader :
sig
  type 'a t

  val int : int t
  val string : string t
  val pair : 'a t -> 'b t -> ('a * 'b) t
  val array : 'a t -> 'a array t

  val read : 'a t -> filename:string -> 'a
end =
struct
  type 'a t = Buffer.t -> in_channel -> 'a

  let junk c =
    try ignore (input_char c)
    with End_of_file -> ()

  let int b c =
    Buffer.clear b;
    let rec loop () =
      match input_char c with
      | exception End_of_file -> ()
      | ' ' -> ()
      | c -> Buffer.add_char b c; loop ()
    in
    loop ();
    int_of_string (Buffer.contents b)

  let string b c =
    let length = int b c in
    let s = really_input_string c length in
    junk c;
    s

  let pair left right b c =
    let l = left b c in
    let r = right b c in
    l, r

  let array element b c =
    let length = int b c in
    Array.init length (fun _index -> element b c)

  let read reader ~filename =
    try_in_channel true filename begin fun c ->
      let magic_number_in_file =
        try really_input_string c (String.length Bisect_common.magic_number_rtd)
        with End_of_file ->
          raise
            (Invalid_file
              (filename, "unexpected end of file while reading magic number"))
      in
      if magic_number_in_file <> Bisect_common.magic_number_rtd then
        raise (Invalid_file (filename, "bad magic number"));

      junk c;

      let b = Buffer.create 4096 in
      try reader b c
      with e ->
        raise
          (Invalid_file
            (filename, "exception reading data: " ^ Printexc.to_string e))
    end
end

let get_relative_path file =
  if Filename.is_relative file then
    file
  else
    let cwd = Sys.getcwd () in
    let cwd_end = String.length cwd in
    let sep_length = String.length Filename.dir_sep in
    let sep_end = sep_length + cwd_end in
    try
      if String.sub file 0 cwd_end = cwd &&
          String.sub file cwd_end sep_length = Filename.dir_sep then
        String.sub file sep_end (String.length file - sep_end)
      else
        file
    with Invalid_argument _ ->
      file

let read_runtime_data filename =
  Reader.(read (array (pair string (pair (array int) string)))) ~filename
  |> Array.to_list
  |> List.map (fun (file, data) -> get_relative_path file, data)

let load_coverage files search_paths expect do_not_expect =
  let data, points =
    let total_counts = Hashtbl.create 17 in
    let points = Hashtbl.create 17 in

    Coverage_input_files.list files search_paths
    |> List.iter (fun out_file ->
      read_runtime_data out_file
      |> List.iter (fun (source_file, (file_counts, file_points)) ->
        let file_counts =
          let open Util.Infix in
          try (Hashtbl.find total_counts source_file) +| file_counts
          with Not_found -> file_counts
        in
        Hashtbl.replace total_counts source_file file_counts;
        Hashtbl.replace points source_file file_points));

    total_counts, points
  in

  let present_files =
    Hashtbl.fold (fun file _ acc -> file::acc) data [] in
  Coverage_input_files.expected_sources_are_present
    present_files expect do_not_expect;

  data, points
