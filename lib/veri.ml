open Core_kernel.Std
open Bap.Std
open Bap_traces.Std

module SM  = Monad.State
open SM.Monad_infix

type event = Trace.event
type 'a u = 'a Bil.Result.u
type 'a r = 'a Bil.Result.r
type 'a e = (event option, 'a) SM.t
type error = Veri_error.t
type policy = Veri_policy.t

let create_move_event tag cell' data' =  
  Value.create tag Move.({cell = cell'; data = data';})

let find tag evs cond =
  let open Option in
  List.find evs ~f:(fun ev -> match Value.get tag ev with
      | None -> false
      | Some mv -> cond mv) >>| fun ev -> Value.get_exn tag ev

let create_mem_store = create_move_event Event.memory_store
let create_mem_load  = create_move_event Event.memory_load
let create_reg_read  = create_move_event Event.register_read
let create_reg_write = create_move_event Event.register_write
let find_reg_read = find Event.register_read
let find_reg_write = find Event.register_write
let find_mem_load = find Event.memory_load
let find_mem_store = find Event.memory_store
let value = Bil.Result.value

module Disasm = struct  
  module Dis = Disasm_expert.Basic
  open Dis
  type t = (asm, kinds) Dis.t

  let insn dis mem = 
    match Dis.insn_of_mem dis mem with
    | Error er -> Error (`Disasm_error er)
    | Ok r -> match r with
      | mem', Some insn, `finished -> Ok (mem',insn)
      | _, None, _ -> 
        let er = Error.of_string "nothing was disasmed" in
        Error (`Disasm_error er)
      | _, _, `left _ -> Error `Overloaded_chunk

  let insn_name = Dis.Insn.name 
end

module Events = Value.Set

class context policy report trace = object(self:'s)
  inherit Veri_traci.context trace as super
  val report : Veri_report.t = report
  val events = Events.empty
  val other = None
  val descr : string option = None
  val error : error option = None

  method merge: 's =
    let report =
      match error with 
      | Some er -> Veri_report.notify report er
      | None ->
        match descr with
        | None -> report
        | Some name ->
          let events = Option.(value_exn self#other)#events in
          let events' = self#events in
          match Veri_policy.denied policy name events events' with
          | [] -> report 
          | results -> Veri_report.update report name results in
    {<other = None; error = None; descr = None;
      events = Events.empty; report = report >}

  method replay =
    let new_i = Option.value_exn other in
    new_i#backup self

  method events: Events.t = events
  method split = self#backup self
  method other = other
  method report = report
  method set_description s = {<descr = Some s >}
  method register_event ev = {< events = Set.add events ev >}
  method notify_error er = {<error = Some er >}
  method backup someone = {<other = Some someone; events = Events.empty >}
end

let target_info arch = 
  let module Target = (val target_of_arch arch) in
  Target.CPU.mem, Target.lift 

let memory_of_chunk endian chunk = 
  Bigstring.of_string (Chunk.data chunk) |>
  Memory.create endian (Chunk.addr chunk) 

let other_events c = match c#other with 
  | None -> []
  | Some c -> Set.to_list c#events

let self_events c = Set.to_list c#events

let same_var  var  mv = var  = Move.cell mv
let same_addr addr mv = addr = Move.cell mv

class ['a] t arch dis is_interesting =
  let endian = Arch.endian arch in
  let mem_var, lift = target_info arch in

  object(self)
    constraint 'a = #context
    inherit ['a] Veri_traci.t arch as super

    method private update_event ev =
      if is_interesting ev then SM.update (fun c -> c#register_event ev)
      else SM.return () 
          
    (** [resolve_var var] - returns a result, bound with [var].
        Sequence of searches is the following:
        1) among read events that occured at current step in the same context,
           with the same variable;
        2) among read events that occures at current step, in other context,
           with the same variable;
        3) in current context, for the same variable *)
    method private resolve_var : var -> 'a r = fun var ->
        SM.get () >>= fun ctxt ->
        match find_reg_read (self_events ctxt) (same_var var) with
        | Some mv -> self#eval_exp (Bil.int (Move.data mv))
        | None -> 
          match find_reg_read (other_events ctxt) (same_var var) with
          | Some mv -> self#eval_exp (Bil.int (Move.data mv))
          | None -> super#lookup var

    (** [lookup var] - returns a result, bound with variable.
        Search starts from self events, if it was write access to given 
        variable at current step. And if it was, then no read events emitted
        and result of write access returned.
        Otherwise searching continues as written above for [resolve_var], 
        with emitting register read event. *)
    method! lookup var : 'a r =
      SM.get () >>= fun ctxt ->
      match find_reg_write (self_events ctxt) (same_var var) with
      | Some mv -> self#eval_exp (Bil.int (Move.data mv))
      | None ->
        self#resolve_var var >>= fun r ->
        match value r with
        | Bil.Imm data ->
          if not (Var.is_virtual var) then
            self#update_event (create_reg_read var data) >>= fun () ->
            SM.return r
          else SM.return r
        | Bil.Mem _ | Bil.Bot -> SM.return r

    method! update var result : 'a u =
      super#update var result >>= fun () ->
      match value result with
      | Bil.Imm data -> 
        if not (Var.is_virtual var) then
          self#update_event (create_reg_write var data)
        else SM.return ()
      | Bil.Mem _ | Bil.Bot -> SM.return ()

    method private eval_mem_event tag addr data : 'a e =
      match value addr, value data with
      | Bil.Imm addr, Bil.Imm data ->
        let ev = create_move_event tag addr data in
        SM.return (Some ev)
      | _ -> SM.return None

    method! eval_store ~mem ~addr data endian size =
      super#eval_store ~mem ~addr data endian size >>= fun r ->
      self#eval_exp addr >>= fun addr ->
      self#eval_exp data >>= fun data ->
      self#eval_mem_event Event.memory_store addr data >>=
      function
      | None -> SM.return r
      | Some ev -> self#update_event ev >>= fun () -> SM.return r

    method private store_and_load ~mem ~addr mv endian size =
      let data = Bil.int (Move.data mv) in
      super#eval_store ~mem ~addr data endian size >>= fun r -> 
      match value r with
      | Bil.Mem _ -> super#update mem_var r >>= fun () -> 
        super#eval_load ~mem ~addr endian size
      | Bil.Imm _ | Bil.Bot -> SM.return r 

    (** [resolve_addr addr] - returns a result, bound with [addr].
        Sequence of searches is the following: 
        1) among load events that occured at current step, in the same context,
           with the same address;
        2) among load events that occures at current step, in other context, 
           with the same address;
        3) in current context. *)
    method private resolve_addr ~mem ~addr endian size =
      self#eval_exp addr >>= fun addr_res ->
      match value addr_res with
      | Bil.Bot | Bil.Mem _ -> SM.return addr_res
      | Bil.Imm addr' ->
        SM.get () >>= fun ctxt ->
        match find_mem_load (self_events ctxt) (same_addr addr') with
        | Some mv -> self#store_and_load ~mem ~addr mv endian size
        | None ->
          match find_mem_load (other_events ctxt) (same_addr addr') with
          | None -> super#eval_load ~mem ~addr endian size
          | Some mv -> self#store_and_load ~mem ~addr mv endian size

    (** [eval_load ~mem ~addr endian size] - returns a result bound with [addr].
        Search starts from self events, if it was write access to given
        address at current step. And if it was, then no load events emitted
        and result of write access returned.
        Otherwise searching continues as written above for [resolve_addr], 
        with emitting memory load event. *)
    method! eval_load ~mem ~addr endian size =
      SM.get () >>= fun ctxt -> 
      self#eval_exp addr >>= fun addr_res ->
      match value addr_res with
      | Bil.Bot | Bil.Mem _ -> SM.return addr_res
      | Bil.Imm addr' ->
        match find_mem_store (self_events ctxt) (same_addr addr') with
        | Some mv -> self#eval_exp (Bil.int (Move.data mv))
        | None ->
          self#resolve_addr mem addr endian size >>= fun r ->          
          self#eval_mem_event Event.memory_load addr_res r >>= fun ev ->
          match ev with
          | Some ev -> self#update_event ev >>= fun () -> SM.return r
          | None -> SM.return r
                  
    method private eval_insn (mem, insn) = 
      let name = Disasm.insn_name insn in
      SM.update (fun c -> c#set_description name) >>= fun () ->
      match lift mem insn with
      | Error er ->
        SM.update (fun c -> c#notify_error (`Lifter_error (name, er)))
      | Ok bil -> self#eval bil
          
    method private eval_chunk chunk =
      match memory_of_chunk endian chunk with
      | Error er -> SM.update (fun c -> c#notify_error (`Damaged_chunk er))
      | Ok mem -> 
        match Disasm.insn dis mem with
        | Error er -> SM.update (fun c -> c#notify_error er)
        | Ok insn -> self#eval_insn insn

    method! eval_event ev = 
      let is_after_code () = 
        SM.get () >>= fun c ->
        List.exists (self_events c) ~f:(Value.is Event.code_exec) |>
        SM.return in
      if Value.is Event.code_exec ev then 
        self#verify_frame >>= fun () -> 
        SM.update (fun c -> c#register_event ev)
      else 
        is_after_code () >>= fun r ->
        if r then self#update_event ev
        else SM.return ()

    method private make_point evs = 
      let code, side = 
        List.fold_left ~init:(None, []) 
          ~f:(fun (code, evs) ev -> 
              match Value.get Event.code_exec ev with
              | None -> code, ev::evs
              | Some chunk as r -> r, evs) evs in
      match code with 
      | None -> None
      | Some code -> Some (code, side)

    method private eval_events evs = 
      List.fold ~init:(SM.return ())
        ~f:(fun sm ev -> sm >>= fun () -> 
             super#eval_event ev >>= fun () ->
             self#update_event ev) evs

    method private verify_frame : 'a u =      
      SM.get () >>= fun ctxt -> 
      match self#make_point (self_events ctxt) with
      | Some (code,side) -> 
        SM.update (fun c -> c#split)  >>= fun () ->
        self#eval_events side      >>= fun () ->
        SM.update (fun c -> c#replay) >>= fun () ->
        self#eval_chunk code       >>= fun () ->
        SM.update (fun c -> c#merge)
      | None -> SM.return ()

    method! eval_trace trace =
      super#eval_trace trace >>= fun () -> self#verify_frame

  end
