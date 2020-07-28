(**************************************************************************)
(*                                                                        *)
(*    Copyright 2020 OCamlPro & Origin Labs                               *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open Ezcmd.TYPES
open EzConfig.OP
open EzFile.OP

let string_of_size nbytes =
  let nbytes = float_of_int nbytes in
  if nbytes > 1_000_000. then
    Printf.sprintf "%.2f MB" ( nbytes /. 1_000_000.)
  else
    Printf.sprintf "%.2f kB" ( nbytes /. 1_024.)

let generate_html_index () =
  let b = Buffer.create 10_000 in
  if Sys.file_exists OpambinGlobals.opambin_header_html then
    Buffer.add_string b ( EzFile.read_file OpambinGlobals.opambin_header_html )
  else begin
    let s = Printf.sprintf {|
<!DOCTYPE html>
<head>
 <meta charset="utf-8">
 <title>%s</title>
</head>
<body>
 <h1>%s</h1>
 <p>Generated by <code><a href="https://ocamlpro.github.io/opam-bin">opam-bin</a> push</code>.</p>
 <p>Example of use:</p>
<pre>
export OPAMROOT=$HOME/opam-root
opam init --bare -n %s/repo
opam switch create alt-ergo 4.07.1 --packages alt-ergo
</pre>
<h2>Available Packages:</h2>
<ul>
|} !!OpambinConfig.title
        !!OpambinConfig.title
        !!OpambinConfig.base_url
    in
    EzFile.write_file ( OpambinGlobals.opambin_header_html ^ ".template" ) s;
    Buffer.add_string b s
  end;
  let current_package = ref None in
  let new_package p =
    if !current_package <> p then begin
      begin
        match !current_package with
        | None -> ()
        | Some _ ->
          Printf.bprintf b " </ul></li>\n"
      end;
      current_package := p ;
      begin
        match p with
        | None -> ()
        | Some package ->
          Printf.bprintf b {|
   <li><p>Package <b>%s</b>:</p><ul>
|} package
      end
    end
  in
  OpambinMisc.iter_repos ~cont:ignore ~opam_repos:[||]
    (fun ~repo ~package ~version ->
       new_package (Some package);
       let version_dir = repo // "packages" // package // version in
       let opam = OpamParser.file ( version_dir // "opam" ) in
       let install = ref false in
       let src = ref None in
       List.iter OpamParserTypes.(function
           | Variable ( _, "install", _ ) -> install := true
           | Section (_,  { section_kind = "url" ; section_items ; _ }) ->
             List.iter (function
                 | Variable ( _, "src", String (_, s) ) ->
                   src := Some s
                 | _ -> ()
               ) section_items
           | _ -> ()
         ) opam.file_contents ;
       let src =
         match !src with
         | None -> "[ no content ]"
         | Some src ->

           let archive_size =
             let st = Unix.lstat ( OpambinGlobals.opambin_store_archives_dir
                                   // ( version ^ "-bin.tar.gz" ) )
             in
             st.Unix.st_size
           in

           Printf.sprintf {| [ <a href="%s"> DOWNLOAD </a> ( %s )] |}
             src
             ( string_of_size archive_size )
       in

       let info =
         let info_file =  version_dir // "files" // "bin-package.info" in
         if Sys.file_exists info_file then begin

           let deps = ref [] in
           let nbytes = ref 0 in
           let nfiles = ref 0 in
           EzFile.iter_lines (fun line ->
               match EzString.split line ':' with
               | "depend" :: name :: versions ->
                 deps := (Printf.sprintf "%s.%s"
                            name ( String.concat ":" versions ) ) :: !deps
               | [ "total" ; n ; "nbytes" ] -> nbytes := int_of_string n
               | [ "total" ; n ; "nfiles" ] -> nfiles := int_of_string n
               | _ -> ()
             ) ( version_dir // "files" // "bin-package.info" );
           match !deps, !nbytes with
           | [], 0 -> ""
           | [ nv ], 0 ->
             Printf.sprintf {| depend: %s |} nv
           | _ ->
             let deps = List.sort compare !deps in
             Printf.sprintf {| <br/>
 <a href="packages/%s/%s/files/bin-package.info"> INFO </a>: %s, %d files,
 depends: %s
|}
               package version
               ( string_of_size ! nbytes )
               !nfiles
               (String.concat " " deps)
         end else
           ""
       in

       Printf.bprintf b {|
       <li>Package <b>%s</b> : [ <a href="packages/%s/%s/opam"> OPAM </a> ]%s%s</li>
|} version
         package version
         src
         info ;
       false
    );
  new_package None;
  Printf.bprintf b {|
 </ul>
</body>
|};

  if Sys.file_exists OpambinGlobals.opambin_trailer_html then
    Buffer.add_string b ( EzFile.read_file OpambinGlobals.opambin_trailer_html )
  else begin
    let s = Printf.sprintf {|
      <hr>
<p>
        Generated by <code>opam-bin</code>, &copy; Copyright 2020, OCamlPro SAS &amp; Origin Labs SAS. &lt;contact@ocamlpro.com&gt;
    </p>
|}
    in
    Buffer.add_string b s ;
    EzFile.write_file ( OpambinGlobals.opambin_trailer_html ^ ".template") s;
  end ;
  Buffer.contents b

let generate_files () =
  Unix.chdir OpambinGlobals.opambin_store_repo_dir;
  OpambinMisc.call [| "opam" ; "admin" ; "index" |];
  Unix.chdir OpambinGlobals.curdir ;

  let html = generate_html_index () in
  EzFile.write_file
    ( OpambinGlobals.opambin_store_repo_dir // "index.html" ) html

let action ~merge ~local_only =
  if !local_only then
    generate_files ()
  else
    match !!OpambinConfig.rsync_url with
    | None ->
      Printf.eprintf
        "Error: you must define the remote url with `%s config --rsync-url`\n%!"
        OpambinGlobals.command ;
      exit 2
    | Some rsync_url ->

      if not !merge then generate_files ();

      let args = [ "rsync"; "-auv" ; "--progress" ] in
      let args = if !merge then args else args @ [ "--delete" ] in
      let args = args @ [
          OpambinGlobals.opambin_store_dir // "." ;
          rsync_url
        ] in
      Printf.eprintf "Calling '%s'\n%!"
        (String.concat " " args);
      OpambinMisc.call (Array.of_list args);
      Printf.eprintf "Done.\n%!";
      ()

let cmd =
  let merge = ref false in
  let local_only = ref false in
  {
    cmd_name = "push" ;
    cmd_action = (fun () -> action ~merge ~local_only) ;
    cmd_args = [

      [ "merge" ], Arg.Set merge,
      Ezcmd.info "Merge instead of deleting non-existent files on the \
                  remote side (do not generate index.tar.gz and \
                  index.html)";

      [ "local-only" ], Arg.Set local_only,
      Ezcmd.info "Generate index.tar.gz and index.html without \
                  upstreaming (for testing purpose)";

    ];
    cmd_man = [];
    cmd_doc = "push binary packages to the remote server";
  }
