function RLCore.Experiment(
    ::Val{:JuliaRL},
    ::Val{:PPO},
    ::Val{:CartPole},
    ::Nothing;
    save_dir = nothing,
    seed = 123,
)
    if isnothing(save_dir)
        t = Dates.format(now(), "yyyy_mm_dd_HH_MM_SS")
        save_dir = joinpath(pwd(), "checkpoints", "JuliaRL_PPO_CartPole_$(t)")
    end

    lg = TBLogger(joinpath(save_dir, "tb_log"), min_level = Logging.Info)
    rng = StableRNG(seed)
    N_ENV = 8
    UPDATE_FREQ = 32
    env = MultiThreadEnv([
        CartPoleEnv(; T = Float32, rng = StableRNG(hash(seed + i))) for i in 1:N_ENV
    ])
    ns, na = length(state(env[1])), length(action_space(env[1]))
    RLBase.reset!(env, is_force = true)
    agent = Agent(
        policy = PPOPolicy(
            approximator = ActorCritic(
                actor = Chain(
                    Dense(ns, 256, relu; init = glorot_uniform(rng)),
                    Dense(256, na; init = glorot_uniform(rng)),
                ),
                critic = Chain(
                    Dense(ns, 256, relu; init = glorot_uniform(rng)),
                    Dense(256, 1; init = glorot_uniform(rng)),
                ),
                optimizer = ADAM(1e-3),
            ) |> cpu,
            γ = 0.99f0,
            λ = 0.95f0,
            clip_range = 0.1f0,
            max_grad_norm = 0.5f0,
            n_epochs = 4,
            n_microbatches = 4,
            actor_loss_weight = 1.0f0,
            critic_loss_weight = 0.5f0,
            entropy_loss_weight = 0.001f0,
            update_freq = UPDATE_FREQ,
        ),
        trajectory = PPOTrajectory(;
            capacity = UPDATE_FREQ,
            state = Matrix{Float32} => (ns, N_ENV),
            action = Vector{Int} => (N_ENV,),
            action_log_prob = Vector{Float32} => (N_ENV,),
            reward = Vector{Float32} => (N_ENV,),
            terminal = Vector{Bool} => (N_ENV,),
        ),
    )

    stop_condition = StopAfterStep(10_000)
    total_reward_per_episode = TotalBatchRewardPerEpisode(N_ENV)
    time_per_step = TimePerStep()
    hook = ComposedHook(
        total_reward_per_episode,
        time_per_step,
        DoEveryNStep() do t, agent, env
            with_logger(lg) do
                @info(
                    "training",
                    actor_loss = agent.policy.actor_loss[end, end],
                    critic_loss = agent.policy.critic_loss[end, end],
                    loss = agent.policy.loss[end, end],
                )
                for i in 1:length(env)
                    if is_terminated(env[i])
                        @info "training" reward = total_reward_per_episode.rewards[i][end] log_step_increment =
                            0
                        break
                    end
                end
            end
        end,
    )

    Experiment(agent, env, stop_condition, hook, "# PPO with CartPole")
end