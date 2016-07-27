open Core_kernel.Std
open Bap.Std
open Bap_traces.Std
open Bap_plugins.Std
open Bap_future.Std
open Veri_policy

module Dis = Disasm_expert.Basic

let () = 
  match Plugins.load () |> Result.all with
  | Ok plugins -> ()
  | Error (path, er) ->
    Printf.eprintf "failed to load plugin from %s: %s" 
      path (Error.to_string_hum er)

module Veri_options = struct
  type t = {
    rules : string option;
    show_errs : bool;
    show_stat : bool;
    path : string;
  } [@@deriving fields]
end

module type Opts = sig
  val options : Veri_options.t
end

module Program (O : Opts) = struct
  open Veri_options
  open O

  let read_rules fname = 
    let comments = "#" in
    let is_sensible s = 
      s <> "" && not (String.is_prefix ~prefix:comments s) in
    let inc = In_channel.create fname in
    let strs = In_channel.input_lines inc in
    In_channel.close inc;
    List.map ~f:String.strip strs 
    |> List.filter ~f:is_sensible
    |> List.map ~f:Veri_rule.of_string_err |>
    List.filter_map ~f:(function 
        | Ok r -> Some r
        | Error er -> 
          Format.(fprintf std_formatter "%s\n" (Error.to_string_hum er));
          None)

  let string_of_error = function
    | `Protocol_error er -> 
      Printf.sprintf "protocol error: %s" 
        (Info.to_string_hum (Error.to_info er))
    | `System_error er -> 
      Printf.sprintf "system error: %s" (Unix.error_message er)
    | `No_provider -> "no provider"
    | `Ambiguous_uri -> "ambiguous uri"

  let default_policy = 
    let open Veri_rule in  
    let p = Veri_policy.(add empty (create_exn ~insn:".*" ~left:".*" deny)) in
    Veri_policy.add p (create_exn ~insn:".*" ~right:".*" deny)

  let make_policy = function
    | None -> default_policy
    | Some file -> 
      read_rules file |>
      List.fold ~f:Veri_policy.add ~init:Veri_policy.empty

  let errors_stream s = 
    let pp_result fmt report  = 
      Format.fprintf fmt "%a" Veri.Report.pp report;
      Format.print_flush () in
    ignore(Stream.subscribe s (pp_result Format.std_formatter))
  
  let is_interesting ev = not (Value.is Event.context_switch ev)
  
  let eval_file file stat policy  = 
    let mk_er s = Error (Error.of_string s) in
    let uri = Uri.of_string ("file:" ^ file) in
    match Trace.load uri with
    | Error er -> 
      Printf.sprintf "error during loading trace: %s\n" (string_of_error er) |>
      mk_er 
    | Ok trace ->
      match Dict.find (Trace.meta trace) Meta.arch with
      | None -> mk_er "trace of unknown arch"
      | Some arch ->
        Dis.with_disasm ~backend:"llvm" (Arch.to_string arch) ~f:(fun dis ->
            let dis = Dis.store_asm dis |> Dis.store_kinds in          
            let ctxt = new Veri.context stat policy trace in
            let veri = new Veri.t arch dis is_interesting in
            if options.show_errs then errors_stream ctxt#reports;
            let ctxt' = Monad.State.exec (veri#eval_trace trace) ctxt in
            Ok ctxt'#stat)

  let print_summary stat =
    let s = Veri_stat.make_summary stat in
    Format.(fprintf std_formatter "%a\n" Veri_stat.Summary.pp s) 

  let read_dir path = 
    let dir = Unix.opendir path in
    let fullpath file = String.concat ~sep:"/" [path; file] in
    let is_trace file = Filename.check_suffix file ".frames" in
    let next () = 
      try 
        Some (Unix.readdir dir)
      with End_of_file -> None in
    let rec folddir acc = 
      match next () with
      | Some file -> 
        if is_trace file then folddir (fullpath file :: acc) 
        else folddir acc 
      | None -> acc in
    let files = folddir [] in
    Unix.closedir dir;
    files

  let main () =   
    let files = 
      if Sys.is_directory options.path then (read_dir options.path)
      else [options.path] in
    let policy = make_policy options.rules in
    let eval stat file = 
      Format.(fprintf std_formatter "%s@." file);
      match eval_file file stat policy with
      | Error er -> 
        Error.to_string_hum er |>
        Printf.eprintf "error in verification: %s";
        stat
      | Ok stat' -> stat' in
    let stat = List.fold ~init:(Veri_stat.create ()) ~f:eval files in
    if options.show_stat then Veri_stat.pp Format.std_formatter stat;
    print_summary stat

end


module Command = struct

  open Cmdliner

  let filename = 
    let doc = 
      "Input file with extension .frames of directory with .frames files" in 
    Arg.(required & pos 0 (some string) None & info [] ~doc ~docv:"FILE | DIR") 
      
  let rules =
    let doc = "File with policy description" in
    Arg.(value & opt (some non_dir_file) None & info ["rules"] ~docv:"FILE" ~doc)

  let show_errors = 
    let doc = "Show detailed information about BIL errors." in
    Arg.(value & flag & info ["show-errors"] ~doc)
      
  let show_stat = 
    let doc = "Show verification summary" in
    Arg.(value & flag & info ["show-stat"] ~doc)
     
  let info =
    let doc = "Bil verification tool" in
    let man = [
      `S "DESCRIPTION";
      `P "Veri is a BIL verification tool and intend to verify BAP lifters
          and to find errors.";
    ] in
    Term.info "veri" ~doc ~man

  let create a b c d = Veri_options.Fields.create a b c d 

  let run_t = Term.(const create $ rules $ show_errors $ show_stat $ filename)

  let filter_argv argv = 
    let ours = [ "rules"; "show-errors"; "show-stat"; ] in
    let prefix = "--" in
    let is_our arg = 
      if String.is_prefix arg ~prefix then
        List.exists ours ~f:(fun a -> prefix ^ a = arg) 
      else true in
    Array.filter ~f:is_our argv

  let parse argv = 
    let argv = filter_argv argv in
    match Term.eval ~argv (run_t, info) ~catch:false with
    | `Ok opts -> Ok opts
    | `Error `Parse -> exit 64
    | `Error _ -> exit 2
    | _ -> exit 1

  let run () = match Term.eval (run_t, info) with `Error _ -> exit 1 | _ -> exit 0

end

let start options =
  let module Program = Program(struct
      let options = options
    end) in
  Ok (Program.main ())

let get_opt ~default  argv opt  =
  Option.value (fst (Cmdliner.Term.eval_peek_opts ~argv opt)) ~default

let () = 
  let open Or_error in
  match Command.parse Sys.argv >>= start with
  | Ok _ -> exit 0
  | Error err -> exit 64 
