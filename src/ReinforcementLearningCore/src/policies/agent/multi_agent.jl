export MultiAgentPolicy
export MultiAgentHook

using Random # for RandomPolicy

import Base.getindex
import Base.iterate
import Base.push!

"""
    MultiAgentPolicy(agents::NT) where {NT<: NamedTuple}
MultiAgentPolicy is a policy struct that contains `<:AbstractPolicy` structs indexed by the player's symbol.
"""
struct MultiAgentPolicy{names,T} <: AbstractPolicy
    agents::NamedTuple{names,T}

    function MultiAgentPolicy(agents::NamedTuple{names,T}) where {names,T}
        new{names,T}(agents)
    end
end

"""
    MultiAgentHook(hooks::NT) where {NT<: NamedTuple}
MultiAgentHook is a hook struct that contains `<:AbstractHook` structs indexed by the player's symbol.
"""
struct MultiAgentHook{names,T} <: AbstractHook
    hooks::NamedTuple{names,T}

    function MultiAgentHook(hooks::NamedTuple{names,T}) where {names,T}
        new{names,T}(hooks)
    end
end

"""
    CurrentPlayerIterator(env::E) where {E<:AbstractEnv}
`CurrentPlayerIterator`` is an iterator that iterates over the players in the environment, returning the `current_player`` for each iteration. This is only necessary for `MultiAgent` environments. After each iteration, `RLBase.next_player!` is called to advance the `current_player`. As long as ``RLBase.next_player!` is defined for the environment, this iterator will work correctly in the `Base.run`` function.
"""
struct CurrentPlayerIterator{E<:AbstractEnv}
    env::E
end

Base.iterate(current_player_iterator::CurrentPlayerIterator) =
    (current_player(current_player_iterator.env), current_player_iterator.env)

function Base.iterate(current_player_iterator::CurrentPlayerIterator, state)
    RLBase.next_player!(current_player_iterator.env)
    return (current_player(current_player_iterator.env), state)
end

Base.iterate(p::MultiAgentPolicy) = iterate(p.agents)
Base.iterate(p::MultiAgentPolicy, s) = iterate(p.agents, s)

Base.getindex(p::MultiAgentPolicy, s::Symbol) = p.agents[s]
Base.getindex(h::MultiAgentHook, s::Symbol) = h.hooks[s]

Base.keys(p::MultiAgentPolicy) = keys(p.agents)
Base.keys(p::MultiAgentHook) = keys(p.hooks)


"""
    Base.run(
        multiagent_policy::MultiAgentPolicy,
        env::E,
        stop_condition,
        hook::MultiAgentHook,
        reset_condition,
    ) where {E<:AbstractEnv, H<:AbstractHook}
This run function dispatches games using `MultiAgentPolicy` and `MultiAgentHook` to the appropriate `run` function based on the `Sequential` or `Simultaneous` trait of the environment.
"""
function Base.run(
    multiagent_policy::MultiAgentPolicy,
    env::E,
    stop_condition::AbstractStopCondition,
    hook::MultiAgentHook,
    reset_condition::AbstractResetCondition=ResetAtTerminal()
) where {E<:AbstractEnv}
    keys(multiagent_policy) == keys(hook) || throw(ArgumentError("MultiAgentPolicy and MultiAgentHook must have the same keys"))
    Base.run(
        multiagent_policy,
        env,
        DynamicStyle(env), # Dispatch on sequential / simultaneous traits
        stop_condition,
        hook,
        reset_condition,
    )
end

"""
    Base.run(
        multiagent_policy::MultiAgentPolicy,
        env::E,
        ::Sequential,
        stop_condition,
        hook::MultiAgentHook,
        reset_condition,
    ) where {E<:AbstractEnv, H<:AbstractHook}
This run function handles `MultiAgent` games with the `Sequential` trait. It iterates over the `current_player` for each turn in the environment, and runs the full `run` loop, like in the `SingleAgent` case. If the `stop_condition` is met, the function breaks out of the loop and calls `optimise!` on the policy again. Finally, it calls `optimise!` on the policy one last time and returns the `MultiAgentHook`.
"""
function Base.run(
    multiagent_policy::MultiAgentPolicy,
    env::E,
    ::Sequential,
    stop_condition::AbstractStopCondition,
    multiagent_hook::MultiAgentHook,
    reset_condition::AbstractResetCondition=ResetAtTerminal(),
) where {E<:AbstractEnv}
    push!(multiagent_hook, PreExperimentStage(), multiagent_policy, env)
    push!(multiagent_policy, PreExperimentStage(), env)
    is_stop = false
    while !is_stop
        reset!(env)
        push!(multiagent_policy, PreEpisodeStage(), env)
        optimise!(multiagent_policy, PreEpisodeStage())
        push!(multiagent_hook, PreEpisodeStage(), multiagent_policy, env)

        while !(reset_condition(multiagent_policy, env) || is_stop) # one episode
            for player in CurrentPlayerIterator(env)
                policy = multiagent_policy[player] # Select appropriate policy
                hook = multiagent_hook[player] # Select appropriate hook
                push!(policy, PreActStage(), env)
                optimise!(policy, PreActStage())
                push!(hook, PreActStage(), policy, env)
                
                action = RLBase.plan!(policy, env)
                act!(env, action)

                

                push!(policy, PostActStage(), env)
                optimise!(policy, PostActStage())
                push!(hook, PostActStage(), policy, env)

                if check_stop(stop_condition, policy, env)
                    is_stop = true
                    push!(multiagent_policy, PreActStage(), env)
                    optimise!(multiagent_policy, PreActStage())
                    push!(multiagent_hook, PreActStage(), policy, env)
                    RLBase.plan!(multiagent_policy, env)  # let the policy see the last observation
                    break
                end

                if reset_condition(multiagent_policy, env)
                    break
                end
            end
        end # end of an episode

        push!(multiagent_policy, PostEpisodeStage(), env)  # let the policy see the last observation
        optimise!(multiagent_policy, PostEpisodeStage())
        push!(multiagent_hook, PostEpisodeStage(), multiagent_policy, env)
    end
    push!(multiagent_policy, PostExperimentStage(), env)
    push!(multiagent_hook, PostExperimentStage(), multiagent_policy, env)
    multiagent_policy
end


"""
    Base.run(
        multiagent_policy::MultiAgentPolicy,
        env::E,
        ::Simultaneous,
        stop_condition,
        hook::MultiAgentHook,
        reset_condition,
    ) where {E<:AbstractEnv, H<:AbstractHook}
This run function handles `MultiAgent` games with the `Simultaneous` trait. It iterates over the players in the environment, and for each player, it selects the appropriate policy from the `MultiAgentPolicy`. All agent actions are collected before the environment is updated. After each player has taken an action, it calls `optimise!` on the policy. If the `stop_condition` is met, the function breaks out of the loop and calls `optimise!` on the policy again. Finally, it calls `optimise!` on the policy one last time and returns the `MultiAgentHook`.
"""
function Base.run(
    multiagent_policy::MultiAgentPolicy,
    env::E,
    ::Simultaneous,
    stop_condition::AbstractStopCondition,
    hook::MultiAgentHook,
    reset_condition::AbstractResetCondition=ResetAtTerminal(),
) where {E<:AbstractEnv}
    RLCore._run(
        multiagent_policy,
        env,
        stop_condition,
        hook,
        reset_condition,
    )
end

# Default behavior for multi-agent, simultaneous `push!` is to iterate over all players and call `push!` on the appropriate policy
function Base.push!(multiagent::MultiAgentPolicy, stage::S, env::E) where {S<:AbstractStage, E<:AbstractEnv}
    for player in players(env)
        push!(multiagent[player], stage, env, player)
    end
end

# Like in the single-agent case, push! at the PreActStage() calls push! on each player with the state of the environment
function Base.push!(multiagent::MultiAgentPolicy{names, T}, ::PreActStage, env::E) where {E<:AbstractEnv, names, T <: Agent}
    for player in players(env)
        push!(multiagent[player], state(env, player))
    end
end

# Like in the single-agent case, push! at the PostActStage() calls push! on each player with the reward and termination status of the environment
function Base.push!(multiagent::MultiAgentPolicy{names, T}, ::PostActStage, env::E) where {E<:AbstractEnv, names, T <: Agent}
    for player in players(env)
        push!(multiagent[player].cache, reward(env, player), is_terminated(env))
    end
end

function Base.push!(hook::MultiAgentHook, stage::S, multiagent::MultiAgentPolicy, env::E) where {E<:AbstractEnv,S<:AbstractStage}
    for player in players(env)
        push!(hook[player], stage, multiagent[player], env, player)
    end
end

@inline function _push!(stage::AbstractStage, policy::P, env::E, player::Symbol, hook::H, hook_tuple...) where {P <: AbstractPolicy, E <: AbstractEnv, H <: AbstractHook}
    push!(hook, stage, policy, env, player)
    _push!(stage, policy, env, player, hook_tuple...)
end

_push!(stage::AbstractStage, policy::P, env::E, player::Symbol) where {P <: AbstractPolicy, E <: AbstractEnv} = nothing

function Base.push!(composed_hook::ComposedHook{T},
                            stage::AbstractStage,
                            policy::P,
                            env::E,
                            player::Symbol
                            ) where {T <: Tuple, P <: AbstractPolicy, E <: AbstractEnv}
    _push!(stage, policy, env, player, composed_hook.hooks...)
end

function RLBase.plan!(multiagent::MultiAgentPolicy, env::E) where {E<:AbstractEnv}
    return (RLBase.plan!(multiagent[player], env, player) for player in players(env))
end

function RLBase.optimise!(multiagent::MultiAgentPolicy, stage::S) where {S<:AbstractStage}
    for policy in multiagent
        RLCore.optimise!(policy, stage)
    end
end
