%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_queue_mode_manager).

-behaviour(gen_server2).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-export([register/4, report_memory/2, report_memory/5, info/0]).

-define(TOTAL_TOKENS, 1000).
-define(ACTIVITY_THRESHOLD, 25).
-define(INITIAL_TOKEN_ALLOCATION, 10).

-define(SERVER, ?MODULE).

-ifdef(use_specs).

-type(queue_mode() :: ( 'mixed' | 'disk' )).

-spec(start_link/0 :: () ->
              ({'ok', pid()} | 'ignore' | {'error', any()})).
-spec(register/4 :: (pid(), atom(), atom(), list()) -> {'ok', queue_mode()}).
-spec(report_memory/5 :: (pid(), non_neg_integer(),
                          non_neg_integer(), non_neg_integer(), bool()) ->
             'ok').

-endif.

-record(state, { available_tokens,
                 mixed_queues,
                 callbacks,
                 tokens_per_byte,
                 lowrate,
                 hibernate
               }).

start_link() ->
    gen_server2:start_link({local, ?SERVER}, ?MODULE, [], []).

register(Pid, Module, Function, Args) ->
    gen_server2:call(?SERVER, {register, Pid, Module, Function, Args}).

report_memory(Pid, Memory) ->
    report_memory(Pid, Memory, undefined, undefined, false).

report_memory(Pid, Memory, Gain, Loss, Hibernating) ->
    gen_server2:cast(?SERVER,
                     {report_memory, Pid, Memory, Gain, Loss, Hibernating}).

info() ->
    gen_server2:call(?SERVER, info).

init([]) ->
    process_flag(trap_exit, true),
    %% todo, fix up this call as os_mon may not be running
    {MemTotal, MemUsed, _BigProc} = memsup:get_memory_data(),
    MemAvail = (MemTotal - MemUsed) / 3, %% magic
    {ok, #state { available_tokens = ?TOTAL_TOKENS,
                  mixed_queues = dict:new(),
                  callbacks = dict:new(),
                  tokens_per_byte = ?TOTAL_TOKENS / MemAvail,
                  lowrate = priority_queue:new(),
                  hibernate = queue:new()
                }}.

handle_call({register, Pid, Module, Function, Args}, _From,
            State = #state { callbacks = Callbacks }) ->
    _MRef = erlang:monitor(process, Pid),
    State1 = State #state { callbacks = dict:store
                            (Pid, {Module, Function, Args}, Callbacks) },
    State2 = #state { available_tokens = Avail,
                      mixed_queues = Mixed } =
        free_upto(Pid, ?INITIAL_TOKEN_ALLOCATION, State1),
    {Result, State3} =
        case ?INITIAL_TOKEN_ALLOCATION > Avail of
            true ->
                {disk, State2};
            false ->
                {mixed, State2 #state { 
                          available_tokens =
                          Avail - ?INITIAL_TOKEN_ALLOCATION,
                          mixed_queues = dict:store
                          (Pid, {?INITIAL_TOKEN_ALLOCATION, active}, Mixed) }}
        end,
    {reply, {ok, Result}, State3};

handle_call(info, _From, State) ->
    State1 = #state { available_tokens = Avail,
                      mixed_queues = Mixed,
                      lowrate = Lazy,
                      hibernate = Sleepy } =
        free_upto(undef, 1 + ?TOTAL_TOKENS, State), %% this'll just do tidying
    {reply, [{ available_tokens, Avail },
             { mixed_queues, dict:to_list(Mixed) },
             { lowrate_queues, priority_queue:to_list(Lazy) },
             { hibernated_queues, queue:to_list(Sleepy) }], State1}.

                                              
handle_cast({report_memory, Pid, Memory, BytesGained, BytesLost, Hibernating},
            State = #state { mixed_queues = Mixed,
                             available_tokens = Avail,
                             callbacks = Callbacks,
                             tokens_per_byte = TPB }) ->
    Req = rabbit_misc:ceil(TPB * Memory),
    LowRate = case {BytesGained, BytesLost} of
                  {undefined, _} -> false;
                  {_, undefined} -> false;
                  {G, L} -> G < ?ACTIVITY_THRESHOLD andalso
                            L < ?ACTIVITY_THRESHOLD
              end,
    {StateN = #state { lowrate = Lazy, hibernate = Sleepy }, ActivityNew} =
        case find_queue(Pid, Mixed) of
            {mixed, {OAlloc, _OActivity}} ->
                Avail1 = Avail + OAlloc,
                State1 = #state { available_tokens = Avail2,
                                  mixed_queues = Mixed1 } =
                    free_upto(Pid, Req,
                              State #state { available_tokens = Avail1 }),
                case Req > Avail2 of
                    true -> %% nowt we can do, send to disk
                        {Module, Function, Args} = dict:fetch(Pid, Callbacks),
                        ok = erlang:apply(Module, Function, Args ++ [disk]),
                        {State1 #state { mixed_queues =
                                         dict:erase(Pid, Mixed1) },
                         disk};
                    false -> %% keep mixed
                        Activity = if Hibernating -> hibernate;
                                      LowRate -> lowrate;
                                      true -> active
                                   end,
                        {State1 #state
                         { mixed_queues =
                           dict:store(Pid, {Req, Activity}, Mixed1),
                           available_tokens = Avail2 - Req },
                         Activity}
                end;
            disk ->
                State1 = #state { available_tokens = Avail1,
                                  mixed_queues = Mixed1 } =
                    free_upto(Pid, Req, State),
                case Req > Avail1 of
                    true -> %% not enough space, stay as disk
                        {State1, disk};
                    false -> %% can go to mixed mode
                        {Module, Function, Args} = dict:fetch(Pid, Callbacks),
                        ok = erlang:apply(Module, Function, Args ++ [mixed]),
                        Activity = if Hibernating -> hibernate;
                                      LowRate -> lowrate;
                                      true -> active
                                   end,
                        {State1 #state {
                           mixed_queues =
                           dict:store(Pid, {Req, Activity}, Mixed1),
                           available_tokens = Avail1 - Req },
                         disk}
                end
        end,
    StateN1 =
        case ActivityNew of
            active -> StateN;
            disk -> StateN;
            lowrate -> StateN #state { lowrate =
                                       priority_queue:in(Pid, Req, Lazy) };
            hibernate -> StateN #state { hibernate =
                                         queue:in(Pid, Sleepy) }
        end,
    {noreply, StateN1}.

handle_info({'DOWN', _MRef, process, Pid, _Reason},
            State = #state { available_tokens = Avail,
                             mixed_queues = Mixed }) ->
    State1 = case find_queue(Pid, Mixed) of
                 disk ->
                     State;
                 {mixed, {Alloc, _Activity}} ->
                     State #state { available_tokens = Avail + Alloc,
                                    mixed_queues = dict:erase(Pid, Mixed) }
             end,
    {noreply, State1};
handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    State.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

find_queue(Pid, Mixed) ->
    case dict:find(Pid, Mixed) of
        {ok, Value} -> {mixed, Value};
        error -> disk
    end.

tidy_and_sum_lazy(IgnorePid, Lazy, Mixed) ->
    tidy_and_sum_lazy(sets:add_element(IgnorePid, sets:new()),
                      Lazy, Mixed, 0, priority_queue:new()).

tidy_and_sum_lazy(DupCheckSet, Lazy, Mixed, FreeAcc, LazyAcc) ->
    case priority_queue:pout(Lazy) of
        {empty, Lazy} -> {FreeAcc, LazyAcc};
        {{value, Pid, Alloc}, Lazy1} ->
            case sets:is_element(Pid, DupCheckSet) of
                true ->
                    tidy_and_sum_lazy(DupCheckSet, Lazy1, Mixed, FreeAcc,
                                      LazyAcc);
                false ->
                    DupCheckSet1 = sets:add_element(Pid, DupCheckSet),
                    case find_queue(Pid, Mixed) of
                        {mixed, {Alloc, lowrate}} ->
                            tidy_and_sum_lazy(DupCheckSet1, Lazy1, Mixed,
                                              FreeAcc + Alloc, priority_queue:in
                                              (Pid, Alloc, LazyAcc));
                        _ ->
                            tidy_and_sum_lazy(DupCheckSet1, Lazy1, Mixed,
                                              FreeAcc, LazyAcc)
                    end
            end
    end.
            
tidy_and_sum_sleepy(IgnorePid, Sleepy, Mixed) ->
    tidy_and_sum_sleepy(sets:add_element(IgnorePid, sets:new()),
                        Sleepy, Mixed, 0, queue:new()).

tidy_and_sum_sleepy(DupCheckSet, Sleepy, Mixed, FreeAcc, SleepyAcc) ->
    case queue:out(Sleepy) of
        {empty, Sleepy} -> {FreeAcc, SleepyAcc};
        {{value, Pid}, Sleepy1} ->
            case sets:is_element(Pid, DupCheckSet) of
                true ->
                    tidy_and_sum_sleepy(DupCheckSet, Sleepy1, Mixed, FreeAcc,
                                        SleepyAcc);
                false ->
                    DupCheckSet1 = sets:add_element(Pid, DupCheckSet),
                    case find_queue(Pid, Mixed) of
                        {mixed, {Alloc, hibernate}} ->
                            tidy_and_sum_sleepy(DupCheckSet1, Sleepy1, Mixed,
                                                FreeAcc + Alloc, queue:in
                                                (Pid, SleepyAcc));
                        _ -> tidy_and_sum_sleepy(DupCheckSet1, Sleepy1, Mixed,
                                                 FreeAcc, SleepyAcc)
                    end
            end
    end.

free_upto_lazy(IgnorePid, Callbacks, Lazy, Mixed, Req) ->
    free_upto_lazy(IgnorePid, Callbacks, Lazy, Mixed, Req,
                   priority_queue:new()).

free_upto_lazy(IgnorePid, Callbacks, Lazy, Mixed, Req, LazyAcc) ->
    case priority_queue:pout(Lazy) of
        {empty, Lazy} -> {priority_queue:join(Lazy, LazyAcc), Mixed, Req};
        {{value, IgnorePid, Alloc}, Lazy1} ->
            free_upto_lazy(IgnorePid, Callbacks, Lazy1, Mixed, Req,
                           priority_queue:in(IgnorePid, Alloc, LazyAcc));
        {{value, Pid, Alloc}, Lazy1} ->
            {Module, Function, Args} = dict:fetch(Pid, Callbacks),
            ok = erlang:apply(Module, Function, Args ++ [disk]),
            Mixed1 = dict:erase(Pid, Mixed),
            case Req > Alloc of
                true -> free_upto_lazy(IgnorePid, Callbacks, Lazy1, Mixed1,
                                       Req - Alloc, LazyAcc);
                false -> {priority_queue:join(Lazy1, LazyAcc), Mixed1,
                          Req - Alloc}
            end
    end.

free_upto_sleepy(IgnorePid, Callbacks, Sleepy, Mixed, Req) ->
    free_upto_sleepy(IgnorePid, Callbacks, Sleepy, Mixed, Req, queue:new()).

free_upto_sleepy(IgnorePid, Callbacks, Sleepy, Mixed, Req, SleepyAcc) ->
    case queue:out(Sleepy) of
        {empty, Sleepy} -> {queue:join(Sleepy, SleepyAcc), Mixed, Req};
        {{value, IgnorePid}, Sleepy1} ->
            free_upto_sleepy(IgnorePid, Callbacks, Sleepy1, Mixed, Req,
                             queue:in(IgnorePid, SleepyAcc));
        {{value, Pid}, Sleepy1} ->
            {Alloc, hibernate} = dict:fetch(Pid, Mixed),
            {Module, Function, Args} = dict:fetch(Pid, Callbacks),
            ok = erlang:apply(Module, Function, Args ++ [disk]),
            Mixed1 = dict:erase(Pid, Mixed),
            case Req > Alloc of
                true -> free_upto_sleepy(IgnorePid, Callbacks, Sleepy1, Mixed1,
                                         Req - Alloc, SleepyAcc);
                false -> {queue:join(Sleepy1, SleepyAcc), Mixed1, Req - Alloc}
            end
    end.

free_upto(Pid, Req, State = #state { available_tokens = Avail,
                                     mixed_queues = Mixed,
                                     callbacks = Callbacks,
                                     lowrate = Lazy,
                                     hibernate = Sleepy }) ->
    case Req > Avail of
        true ->
            {SleepySum, Sleepy1} = tidy_and_sum_sleepy(Pid, Sleepy, Mixed),
            case Req > Avail + SleepySum of
                true -> %% not enough in sleepy, have a look in lazy too
                    {LazySum, Lazy1} = tidy_and_sum_lazy(Pid, Lazy, Mixed),
                    case Req > Avail + SleepySum + LazySum of
                        true -> %% can't free enough, just return tidied state
                            State #state { lowrate = Lazy1,
                                           hibernate = Sleepy1 };
                        false -> %% need to free all of sleepy, and some of lazy
                            {Sleepy2, Mixed1, ReqRem} =
                                free_upto_sleepy
                                  (Pid, Callbacks, Sleepy1, Mixed, Req),
                            {Lazy2, Mixed2, ReqRem1} =
                                free_upto_lazy(Pid, Callbacks, Lazy1, Mixed1,
                                               ReqRem),
                            State #state { available_tokens =
                                           Avail + (Req - ReqRem1),
                                           mixed_queues = Mixed2,
                                           lowrate = Lazy2,
                                           hibernate = Sleepy2 }
                    end;
                false -> %% enough available in sleepy, don't touch lazy
                    {Sleepy2, Mixed1, ReqRem} =
                        free_upto_sleepy(Pid, Callbacks, Sleepy1, Mixed, Req),
                    State #state { available_tokens = Avail + (Req - ReqRem),
                                   mixed_queues = Mixed1,
                                   hibernate = Sleepy2 }
            end;
        false -> State
    end.
