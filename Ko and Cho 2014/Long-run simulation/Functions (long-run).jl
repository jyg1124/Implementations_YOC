__precompile__()

module Functions
  using Distributions, PyPlot, JuMP, Ipopt
  importall Types
  export server_creater, server_setter, arrival_generator, workload_setter,
        update_buffer, generate_NHPP, run_to_end, warm_up, next_event,
        find_min_price_server, p_dot, x_dot, server_power_2nd_diff, server_power_1st_diff,
        server_power, subinterval_setter, stationary_arrival_generator

  # function definitions
  function subinterval_setter(N::Int64, WS::Array{Workload_Setting}) # n: the number of intervals
    SI = Subinterval_Information[]
    for i in 1:length(WS)
      I = Interval[]
      l = WS[i].period_rate_function/N
      for j in 1:N
        m = Model(solver = IpoptSolver(print_level = 0))
        JuMP.registerNLFunction(m, :λ, 1, WS[i].rate_function_inter_arrival, autodiff=true)
        @variable(m, t)
        @NLobjective(m, Max, λ(t))
        @NLconstraint(m, l*(j-1) <= t <= l*j)
        solve(m)
        push!(I, Interval(l*(j-1), l*j, getobjectivevalue(m)))
      end
      push!(SI, Subinterval_Information(I))
    end
    return SI
  end

  function server_power(j::Int64, SS::Array{Server_Setting}, S::Array{Server})
    return SS[j].K + (SS[j].α)*(S[j].current_speed^SS[j].n)
  end

  function server_power_1st_diff(j::Int64, SS::Array{Server_Setting}, S::Array{Server})
    return (SS[j].α)*(SS[j].n)*(S[j].current_speed^((SS[j].n)-1))
  end

  function server_power_2nd_diff(j::Int64, SS::Array{Server_Setting}, S::Array{Server})
    return (SS[j].α)*(SS[j].n)*((SS[j].n)-1)*(S[j].current_speed^((SS[j].n)-2))
  end

  function x_dot(j::Int64, SS::Array{Server_Setting}, S::Array{Server})
    if SS[j].γ < S[j].current_speed < SS[j].Γ
      return S[j].current_price - server_power_1st_diff(j,SS,S)
    elseif S[j].current_speed >= SS[j].Γ
      return min( S[j].current_price - server_power_1st_diff(j,SS,S) , 0.0 )
    elseif S[j].current_speed <= SS[j].γ
      return max( S[j].current_price - server_power_1st_diff(j,SS,S) , 0.0 )
    end
  end

  function p_dot(j::Int64, S::Array{Server})
    if S[j].current_price >= 0.0
      return S[j].κ + S[j].current_remaining_workload - S[j].current_speed
    else
      return max(S[j].κ + S[j].current_remaining_workload - S[j].current_speed, 0.0)
    end
  end

  function find_min_price_server(app_type::Int64, SS::Array{Server_Setting}, S::Array{Server})
    server_index = 0
    temp_price = typemax(Float64)

    for j in 1:length(SS)
      if in(app_type, SS[j].Apps) == true
        if temp_price > S[j].current_price
          temp_price = S[j].current_price
          server_index = j
        end
      end
    end
    return server_index
  end

  function next_event(vdc::VirtualDataCenter, PI::Plot_Information)
    if vdc.next_regular_update == min(vdc.next_regular_update, vdc.next_arrival, vdc.next_completion, vdc.next_buffer_update)
      push!(PI.time_array, vdc.current_time) # 시간 기록
      inter_event_time = vdc.next_regular_update - vdc.current_time   # 지난이벤트와 지금이벤트의 시간간격을 저장
      vdc.current_time = vdc.next_regular_update                      # 시뮬레이터의 현재 시간을 바꿈
      # remaining_workload 업데이트
      for j in 1:length(vdc.S)   # 모든 서버에 대해
        for i in 1:length(vdc.S[j].WIP)   # 각 서버 안에 있는 arrival에 대해
          vdc.S[j].WIP[i].remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 각 arrival의 worklaod를 줄여준다
          vdc.S[j].current_remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 서버 j의 workload 총합을 줄여준다.
        end

        # For plotting speed, price, and κ
        push!(PI.speed_array[j], vdc.S[j].current_speed)
        push!(PI.price_array[j], vdc.S[j].current_price)
        push!(PI.buffer_array[j], vdc.S[j].κ)

        # 스피드 업데이트
        vdc.S[j].previous_speed = vdc.S[j].current_speed
        vdc.S[j].current_speed = (vdc.S[j].previous_speed) + ((1/server_power_2nd_diff(j, vdc.SS, vdc.S))*(x_dot(j, vdc.SS, vdc.S)))

        # price 업데이트
        vdc.S[j].previous_price = vdc.S[j].current_price
        vdc.S[j].current_price = vdc.S[j].previous_price + p_dot(j, vdc.S)
      end

      # completion_time을 계산해야함  (모든 서버들에 대해서 )
      server_index_2 = 0
      WIP_index = 0
      shortest_remaining_time = typemax(Float64)

      for j in 1:length(vdc.S)
        for i in 1:length(vdc.S[j].WIP)
          if shortest_remaining_time > (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            shortest_remaining_time = (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            WIP_index = i
            server_index_2 = j
            vdc.next_completion = vdc.current_time + shortest_remaining_time
            vdc.next_completion_info = Dict("server_num"=>server_index_2, "WIP_num"=>WIP_index)
          end
        end
      end

      if server_index_2 == 0 && WIP_index == 0 # 만약 데이터센터 안에 아무 arrival이 없다면
        vdc.next_completion = typemax(Float64)
        vdc.next_regular_update += vdc.regular_update_interval
      else
        vdc.next_regular_update += vdc.regular_update_interval
      end

    elseif vdc.next_arrival == min(vdc.next_regular_update, vdc.next_arrival, vdc.next_completion, vdc.next_buffer_update)
      inter_event_time = vdc.next_arrival - vdc.current_time   # 지난이벤트와 지금이벤트의 시간간격을 저장
      vdc.current_time = vdc.next_arrival                      # 시뮬레이터의 현재 시간을 바꿈
      println(PI.file_sim_record,"(Time: $(vdc.current_time)) Current event: New arrival ($(vdc.AI[1].arrival_index)th arrival, app_type: $(vdc.AI[1].app_type), workload: $(vdc.AI[1].remaining_workload), server_dispatched: $(find_min_price_server(vdc.AI[1].app_type, vdc.SS, vdc.S))")
#      println("(Time: $(vdc.current_time)) Current event: New arrival ($(vdc.AI[1].arrival_index)th arrival, app_type: $(vdc.AI[1].app_type), workload: $(vdc.AI[1].remaining_workload), server_dispatched: $(find_min_price_server(vdc.AI[1].app_type, vdc.SS, vdc.S))")

      server_index = find_min_price_server(vdc.AI[1].app_type, vdc.SS, vdc.S)    # 일감의 type에 맞춰서 어느 서버로 보내야할지 결정

      vdc.S[server_index].previous_remaining_workload = vdc.S[server_index].current_remaining_workload  # 기존 remaining_workload 저장
      vdc.S[server_index].current_remaining_workload = vdc.S[server_index].previous_remaining_workload + vdc.AI[1].remaining_workload # 현재 remaining_workload에 arriving workload 추가

      for j in 1:length(vdc.S)   # 모든 서버에 대해
        for i in 1:length(vdc.S[j].WIP)   # 각 서버 안에 있는 arrival에 대해
          vdc.S[j].WIP[i].remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 각 arrival의 worklaod를 줄여준다
          vdc.S[j].current_remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 서버 j의 workload 총합을 줄여준다.
        end
        # 스피드 업데이트
        vdc.S[j].previous_speed = vdc.S[j].current_speed
        vdc.S[j].current_speed = vdc.S[j].previous_speed + (1/server_power_2nd_diff(j, vdc.SS, vdc.S))*(x_dot(j, vdc.SS, vdc.S))
        # price 업데이트
        vdc.S[j].previous_price = vdc.S[j].current_price
        vdc.S[j].current_price = vdc.S[j].previous_price + p_dot(j, vdc.S)
      end

      # Updating next completion time   (모든 서버들에 대해서 )
      push!(vdc.S[server_index].WIP, vdc.AI[1]) # 그 서버에 일감 추가
      server_index_2 = 0
      WIP_index = 0
      shortest_remaining_time = typemax(Float64)

      for j in 1:length(vdc.S)
        for i in 1:length(vdc.S[j].WIP)
          if shortest_remaining_time > (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            shortest_remaining_time = (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            WIP_index = i
            server_index_2 = j
            vdc.next_completion = vdc.current_time + shortest_remaining_time
            vdc.next_completion_info = Dict("server_num"=>server_index_2, "WIP_num"=>WIP_index)
          end
        end
      end

      vdc.S[server_index].num_in_server += 1 # 서버안에 있는 일감의 수 ++
      shift!(vdc.AI) # AI에서는 일감하나 뺌
      vdc.next_arrival = vdc.AI[1].arrival_time
    elseif vdc.next_completion == min(vdc.next_regular_update, vdc.next_arrival, vdc.next_completion, vdc.next_buffer_update)
      server_index = vdc.next_completion_info["server_num"]
      WIP_index = vdc.next_completion_info["WIP_num"]
      inter_event_time = vdc.next_completion - vdc.current_time
      vdc.current_time = vdc.next_completion
      println(PI.file_sim_record,"(Time: $(vdc.current_time)) Current event: Completion ($(vdc.passed_arrivals+1)th, server: $server_index , server $server_index's remaining WIPs: $(length(vdc.S[server_index].WIP))")
#      println("(Time: $(vdc.current_time)) Current event: Completion ($(vdc.passed_arrivals+1)th, server: $server_index , server $server_index's remaining WIPs: $(length(vdc.S[server_index].WIP))")

      # for summarizing
      if vdc.warmed_up == true
        if vdc.current_time - vdc.S[server_index].WIP[WIP_index].arrival_time > vdc.SS[server_index].δ
          push!(PI.sojourn_time_array[server_index], 1)
        else
          push!(PI.sojourn_time_array[server_index], 0)
        end
      end

      vdc.S[server_index].previous_remaining_workload = vdc.S[server_index].current_remaining_workload  # 기존 remaining_workload 저장

      for j in 1:length(vdc.S)   # 모든 서버에 대해
        for i in 1:length(vdc.S[j].WIP)   # 각 서버 안에 있는 arrival에 대해
          vdc.S[j].WIP[i].remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 각 arrival의 worklaod를 줄여준다
          vdc.S[j].current_remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 서버 j의 workload 총합을 줄여준다.
        end
        # 스피드 업데이트
        vdc.S[j].previous_speed = vdc.S[j].current_speed
        vdc.S[j].current_speed = vdc.S[j].previous_speed + (1/server_power_2nd_diff(j, vdc.SS, vdc.S))*x_dot(j, vdc.SS, vdc.S)
        # price 업데이트
        vdc.S[j].previous_price = vdc.S[j].current_price
        vdc.S[j].current_price = vdc.S[j].previous_price + p_dot(j, vdc.S)
      end

      # Updating next completion time   (모든 서버들에 대해서 )
      deleteat!(vdc.S[server_index].WIP, WIP_index)
      server_index_2 = 0
      WIP_index = 0
      shortest_remaining_time = typemax(Float64)

      for j in 1:length(vdc.S)
        for i in 1:length(vdc.S[j].WIP)
          if shortest_remaining_time > (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            shortest_remaining_time = (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            WIP_index = i
            server_index_2 = j
            vdc.next_completion = vdc.current_time + shortest_remaining_time
            vdc.next_completion_info = Dict("server_num"=>server_index_2, "WIP_num"=>WIP_index)
          end
        end
      end

      if server_index_2 == 0 && WIP_index == 0 # 만약 데이터센터 안에 아무 arrival이 없다면
        vdc.next_completion = typemax(Float64)
      else
        vdc.S[server_index].num_in_server -= 1 # 서버안에 있는 일감의 수 --
      end
      vdc.passed_arrivals += 1

    elseif vdc.next_buffer_update == min(vdc.next_regular_update, vdc.next_arrival, vdc.next_completion, vdc.next_buffer_update)
      inter_event_time = vdc.next_buffer_update - vdc.current_time
      vdc.current_time = vdc.next_buffer_update
      println(PI.file_sim_record,"(Time: $(vdc.current_time)) Current event: Buffer update (buffer update counter: $(vdc.buffer_update_counter+1), interval index: $((vdc.buffer_update_counter) % (length(vdc.SI[1].interval)) + 1))")
#      println("(Time: $(vdc.current_time)) Current event: Buffer update (buffer update counter: $(vdc.buffer_update_counter+1), interval index: $((vdc.buffer_update_counter) % (length(vdc.SI[1].interval)) + 1))")

#      for i in 1:length(vdc.SI) println(PI.file_sim_record,"vdc.SI[$i].interval[$((vdc.buffer_update_counter) % (length(vdc.SI[i].interval)) + 1)].λ_max: $(vdc.SI[i].interval[((vdc.buffer_update_counter) % (length(vdc.SI[i].interval)) + 1)].λ_max)") end
      update_buffer(vdc)
      for i in 1:length(vdc.WS) println(PI.file_sim_record,"WS[$i].mean_inter_arrival: $(vdc.WS[i].mean_inter_arrival), WS[$i].std_inter_arrival: $(vdc.WS[i].std_inter_arrival)") end
      for j in 1:length(vdc.SI) println(PI.file_sim_record,"S[$j].κ: $(vdc.S[j].κ)") end

      # remaining_workload 업데이트
      for j in 1:length(vdc.S)   # 모든 서버에 대해
        for i in 1:length(vdc.S[j].WIP)   # 각 서버 안에 있는 arrival에 대해
          vdc.S[j].WIP[i].remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 각 arrival의 worklaod를 줄여준다
          vdc.S[j].current_remaining_workload -= (vdc.S[j].current_speed/length(vdc.S[j].WIP))*inter_event_time  # 서버 j의 workload 총합을 줄여준다.
        end

        # 스피드 업데이트
        vdc.S[j].previous_speed = vdc.S[j].current_speed
        vdc.S[j].current_speed = (vdc.S[j].previous_speed) + ((1/server_power_2nd_diff(j, vdc.SS, vdc.S))*(x_dot(j, vdc.SS, vdc.S)))
        # vdc.S[j].current_speed = vdc.SS[j].Γ

        # price 업데이트
        vdc.S[j].previous_price = vdc.S[j].current_price
        vdc.S[j].current_price = vdc.S[j].previous_price + p_dot(j, vdc.S)
      end

      # completion_time을 계산해야함  (모든 서버들에 대해서 )
      server_index_2 = 0
      WIP_index = 0
      shortest_remaining_time = typemax(Float64)

      for j in 1:length(vdc.S)
        for i in 1:length(vdc.S[j].WIP)
          if shortest_remaining_time > (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            shortest_remaining_time = (vdc.S[j].WIP[i].remaining_workload/(vdc.S[j].current_speed/length(vdc.S[j].WIP)))
            WIP_index = i
            server_index_2 = j
            vdc.next_completion = vdc.current_time + shortest_remaining_time
            vdc.next_completion_info = Dict("server_num"=>server_index_2, "WIP_num"=>WIP_index)
          end
        end
      end

      vdc.buffer_update_counter += 1
      n = (vdc.buffer_update_counter) % (length(vdc.SI[1].interval)) + 1  # n:
      # vdc.next_buffer_update = (vdc.WS[1].period_rate_function)*floor(vdc.current_time/vdc.WS[1].period_rate_function) + vdc.SI[1].interval[n].starting_time
      vdc.next_buffer_update += vdc.WS[1].period_rate_function/length(vdc.SI[1].interval)
    end
  end

  function warm_up(vdc::VirtualDataCenter, PI::Plot_Information, WARM_UP_TIME::Float64)
    println(PI.file_sim_record, "Warming up for $(WARM_UP_TIME) times.")
    while vdc.current_time < WARM_UP_TIME
      next_event(vdc, PI)
    end
    vdc.warmed_up = true
    println(PI.file_sim_record, "Warmed up.")
  end

  function warm_up(vdc::VirtualDataCenter, PI::Plot_Information, WARM_UP_ARRIVALS::Int64)
    println(PI.file_sim_record, "Warming up for $(WARM_UP_ARRIVALS) arrivals.")
    while vdc.passed_arrivals < WARM_UP_ARRIVALS
      next_event(vdc, PI)
    end
    vdc.warmed_up = true
    println(PI.file_sim_record, "Warmed up.")
  end

  function run_to_end(vdc::VirtualDataCenter, PI::Plot_Information, REPLICATION_TIME::Float64, WARM_UP_TIME::Float64)
    if !vdc.warmed_up
      warm_up(vdc,PI,WARM_UP_TIME)
    end
    while vdc.current_time < REPLICATION_TIME
      next_event(vdc, PI)
    end
    println(PI.file_sim_record, "Simulation finished")
  end

  function run_to_end(vdc::VirtualDataCenter, PI::Plot_Information, MAX_ARRIVALS::Int64, WARM_UP_ARRIVALS::Int64)
    if !vdc.warmed_up
      warm_up(vdc,PI,WARM_UP_ARRIVALS)
    end
    while vdc.passed_arrivals < MAX_ARRIVALS
      next_event(vdc, PI)
    end
    println(PI.file_sim_record, "Simulation finished")
  end

  function generate_NHPP(f::Function, T::Float64)
    m = Model(solver = IpoptSolver(print_level = 0))
    JuMP.registerNLFunction(m, :λ, 1, f, autodiff=true)
    @variable(m, t)
    @NLobjective(m, Max, λ(t))
    solve(m)
    λ = getobjectivevalue(m)
    x = Float64[]
    t = 0.0
    while t < T
      t -= (1/λ)*log(rand())
      if rand() <= f(t)/λ
        push!(x, t)
      end
    end
    return x
  end

  function generate_NHPP(f::Function, N::Int64)
    m = Model(solver = IpoptSolver(print_level = 0))
    JuMP.registerNLFunction(m, :λ, 1, f, autodiff=true)
    @variable(m, t)
    @NLobjective(m, Max, λ(t))
    solve(m)
    λ = getobjectivevalue(m)
    x = Float64[]
    t = 0.0
    n = 0
    while n < N
      t -= (1/λ)*log(rand())
      if rand() <= f(t)/λ
        push!(x, t)
        n += 1
      end
    end
    return x
  end


  function workload_setter(time_varying::Bool)
    WS = Workload_Setting[]
    if time_varying == true
      push!(WS, Workload_Setting(20.0, "Exponential", 0.25, t -> 4.0-3*sin((π/1000)*t), 1000, 1.0, 0.25,"LogNormal",5.0, 1.5, 5.0*sqrt(1.5)    ) )
      push!(WS, Workload_Setting(20.0, "Exponential", 0.5, t -> 2.0-1.5*sin((π/1000)*t), 1000, 1.0, 0.5, "LogNormal", 10.0, 2.0, 10.0*sqrt(2.0)    ) )
      push!(WS, Workload_Setting(20.0, "Exponential", 0.25, t -> 4.0-2.5*sin((π/1000)*t), 1000, 1.0, 0.25, "LogNormal", 5.0, 1.0, 5.0*sqrt(1.0)    ) )
      push!(WS, Workload_Setting(20.0, "Exponential", 0.1, t -> 10.0-5*sin((π/1000)*t), 1000, 1.0, 0.1, "LogNormal", 2.0, 0.8, 2.0*sqrt(0.8)    ) )
      push!(WS, Workload_Setting(15.0, "Exponential", 0.2, t -> 5.0-4*sin((π/1000)*t), 1000, 1.0, 0.2,"LogNormal", 3.0,0.5, 3.0*sqrt(0.5)    ) )
    else
      push!(WS, Workload_Setting(20.0, "LogNormal", 0.25, t -> 4.0-3*sin((π/1000)*t), 1000, 1.0, 0.25,"LogNormal",5.0, 1.5, 5.0*sqrt(1.5)    ) )
      push!(WS, Workload_Setting(20.0, "LogNormal", 0.5, t -> 2.0-1.5*sin((π/1000)*t), 1000, 1.0, 0.5, "LogNormal", 10.0, 2.0, 10.0*sqrt(2.0)    ) )
      push!(WS, Workload_Setting(20.0, "Exponential", 0.25, t -> 4.0-2.5*sin((π/1000)*t), 1000, 1.0, 0.25, "LogNormal", 5.0, 1.0, 5.0*sqrt(1.0)    ) )
      push!(WS, Workload_Setting(20.0, "LogNormal", 0.1, t -> 10.0-5*sin((π/1000)*t), 1000, 1.0, 0.1, "LogNormal", 2.0, 0.8, 2.0*sqrt(0.8)    ) )
      push!(WS, Workload_Setting(15.0, "LogNormal", 0.2, t -> 5.0-4*sin((π/1000)*t), 1000, 1.0, 0.2,"LogNormal", 3.0,0.5, 3.0*sqrt(0.5)    ) )
    end
    return WS
  end

  function arrival_generator(WS::Array{Workload_Setting}, REPLICATION_TIME::Float64) # condition is either REPLICATION_TIME or MAX_ARRIVALS
    vector_1 = generate_NHPP(WS[1].rate_function_inter_arrival, REPLICATION_TIME+10.0)
    vector_2 = generate_NHPP(WS[2].rate_function_inter_arrival, REPLICATION_TIME+10.0)
    vector_3 = generate_NHPP(WS[3].rate_function_inter_arrival, REPLICATION_TIME+10.0)
    vector_4 = generate_NHPP(WS[4].rate_function_inter_arrival, REPLICATION_TIME+10.0)
    vector_5 = generate_NHPP(WS[5].rate_function_inter_arrival, REPLICATION_TIME+10.0)
    AI = Arrival_Information[]
    m = 0.0
    i = 1
    while m < REPLICATION_TIME + 1.0
      m = min(vector_1[1], vector_2[1], vector_3[1], vector_4[1], vector_5[1])
      if m == vector_1[1]
        push!(AI, Arrival_Information(i,1,m,rand(LogNormal(log(5.0),sqrt(log(1+1.5)))),typemax(Float64)))
        shift!(vector_1)
      elseif m == vector_2[1]
        push!(AI, Arrival_Information(i,2,m,rand(LogNormal(log(10.0),sqrt(log(1+2)))),typemax(Float64)))
        shift!(vector_2)
      elseif m == vector_3[1]
        push!(AI, Arrival_Information(i,3,m,rand(LogNormal(log(5.0),sqrt(log(1+1)))),typemax(Float64)))
        shift!(vector_3)
      elseif m == vector_4[1]
        push!(AI, Arrival_Information(i,4,m,rand(LogNormal(log(2.0),sqrt(log(0.8+1)))),typemax(Float64)))
        shift!(vector_4)
      else
        push!(AI, Arrival_Information(i,5,m,rand(LogNormal(log(3.0),sqrt(log(0.5+1)))),typemax(Float64)))
        shift!(vector_5)
      end
      i += 1
    end
    return AI
  end

  function arrival_generator(WS::Array{Workload_Setting}, MAX_ARRIVALS::Int64) # condition is either REPLICATION_TIME or MAX_ARRIVALS
    vector_1 = generate_NHPP(WS[1].rate_function_inter_arrival, MAX_ARRIVALS + 10)
    vector_2 = generate_NHPP(WS[2].rate_function_inter_arrival, MAX_ARRIVALS + 10)
    vector_3 = generate_NHPP(WS[3].rate_function_inter_arrival, MAX_ARRIVALS + 10)
    vector_4 = generate_NHPP(WS[4].rate_function_inter_arrival, MAX_ARRIVALS + 10)
    vector_5 = generate_NHPP(WS[5].rate_function_inter_arrival, MAX_ARRIVALS + 10)
    AI = Arrival_Information[]
    m = 0.0
    i = 1
    while i < MAX_ARRIVALS*2
      m = min(vector_1[1], vector_2[1], vector_3[1], vector_4[1], vector_5[1])
      if m == vector_1[1]
        push!(AI, Arrival_Information(i,1,m,rand(LogNormal(log(5.0),sqrt(log(1+1.5)))),typemax(Float64)))
        shift!(vector_1)
      elseif m == vector_2[1]
        push!(AI, Arrival_Information(i,2,m,rand(LogNormal(log(10.0),sqrt(log(1+2)))),typemax(Float64)))
        shift!(vector_2)
      elseif m == vector_3[1]
        push!(AI, Arrival_Information(i,3,m,rand(LogNormal(log(5.0),sqrt(log(1+1)))),typemax(Float64)))
        shift!(vector_3)
      elseif m == vector_4[1]
        push!(AI, Arrival_Information(i,4,m,rand(LogNormal(log(2.0),sqrt(log(0.8+1)))),typemax(Float64)))
        shift!(vector_4)
      else
        push!(AI, Arrival_Information(i,5,m,rand(LogNormal(log(3.0),sqrt(log(0.5+1)))),typemax(Float64)))
        shift!(vector_5)
      end
      i += 1
    end
    return AI
  end

  function stationary_arrival_generator(WS::Array{Workload_Setting}, MAX_ARRIVALS::Int64) # condition is either REPLICATION_TIME or MAX_ARRIVALS
    vector_1 = rand(Distributions.LogNormal(log(0.25),sqrt(log(2+1))), MAX_ARRIVALS+10)
    vector_2 = rand(Distributions.LogNormal(log(0.5),sqrt(log(1.5+1))), MAX_ARRIVALS+10)
    vector_3 = rand(Distributions.Exponential(4), MAX_ARRIVALS+10)
    vector_4 = rand(Distributions.LogNormal(log(0.1),0.1*sqrt(log(1+0.8))), MAX_ARRIVALS+10)
    vector_5 = rand(Distributions.LogNormal(log(0.2),0.2*sqrt(log(1+2))), MAX_ARRIVALS+10)

    i = 1
    while i < MAX_ARRIVALS+10
      vector_1[i+1] = vector_1[i] + vector_1[i+1]
      vector_2[i+1] = vector_2[i] + vector_2[i+1]
      vector_3[i+1] = vector_3[i] + vector_3[i+1]
      vector_4[i+1] = vector_4[i] + vector_4[i+1]
      vector_5[i+1] = vector_5[i] + vector_5[i+1]
      i += 1
    end
    AI = Arrival_Information[]
    i = 1
    while i < MAX_ARRIVALS+10
      m = min(vector_1[1], vector_2[1], vector_3[1], vector_4[1], vector_5[1])
      if m == vector_1[1]
        push!(AI, Arrival_Information(i,1,m,rand(LogNormal(log(5.0),sqrt(log(1+1.5)))),typemax(Float64)))
        shift!(vector_1)
      elseif m == vector_2[1]
        push!(AI, Arrival_Information(i,2,m,rand(LogNormal(log(10.0),sqrt(log(1+2)))),typemax(Float64)))
        shift!(vector_2)
      elseif m == vector_3[1]
        push!(AI, Arrival_Information(i,3,m,rand(LogNormal(log(5.0),sqrt(log(1+1)))),typemax(Float64)))
        shift!(vector_3)
      elseif m == vector_4[1]
        push!(AI, Arrival_Information(i,4,m,rand(LogNormal(log(2.0),sqrt(log(0.8+1)))),typemax(Float64)))
        shift!(vector_4)
      else
        push!(AI, Arrival_Information(i,5,m,rand(LogNormal(log(3.0),sqrt(log(0.5+1)))),typemax(Float64)))
        shift!(vector_5)
      end
      i += 1
    end
    return AI
  end

  function stationary_arrival_generator(WS::Array{Workload_Setting}, REPLICATION_TIME::Float64) # condition is either REPLICATION_TIME or MAX_ARRIVALS
    vector_1 = rand(Distributions.LogNormal(log(0.25),sqrt(log(2+1))), 1)
    vector_2 = rand(Distributions.LogNormal(log(0.5),sqrt(log(1.5+1))), 1)
    vector_3 = rand(Distributions.Exponential(4), 1)
    vector_4 = rand(Distributions.LogNormal(log(0.1),0.1*sqrt(log(1+0.8))), 1)
    vector_5 = rand(Distributions.LogNormal(log(0.2),0.2*sqrt(log(1+2))), 1)
    i = 1
    t = 0.0
    while t < REPLICATION_TIME + 100
      push!(vector_1[i+1], vector_1[i] + rand(Distributions.LogNormal(log(0.25),sqrt(log(2+1))))  )
      push!(vector_2[i+1], vector_2[i] + rand(Distributions.LogNormal(log(0.5),sqrt(log(1.5+1))))  )
      push!(vector_3[i+1], vector_3[i] + rand(Distributions.Exponential(4))  )
      push!(vector_4[i+1], vector_4[i] + rand(Distributions.LogNormal(log(0.1),0.1*sqrt(log(1+0.8))))  )
      push!(vector_5[i+1], vector_5[i] + rand(Distributions.LogNormal(log(0.2),0.2*sqrt(log(1+2))))  )
      i += 1
      t = min(vector_1[i+1],vector_2[i+1],vector_3[i+1],vector_4[i+1],vector_5[i+1])
    end

    AI = Arrival_Information[]
    i = 1
    while m < REPLICATION_TIME + 1
      m = min(vector_1[1], vector_2[1], vector_3[1], vector_4[1], vector_5[1])
      if m == vector_1[1]
        push!(AI, Arrival_Information(i,1,m,rand(LogNormal(log(5.0),sqrt(log(1+1.5)))),typemax(Float64)))
        shift!(vector_1)
      elseif m == vector_2[1]
        push!(AI, Arrival_Information(i,2,m,rand(LogNormal(log(10.0),sqrt(log(1+2)))),typemax(Float64)))
        shift!(vector_2)
      elseif m == vector_3[1]
        push!(AI, Arrival_Information(i,3,m,rand(LogNormal(log(5.0),sqrt(log(1+1)))),typemax(Float64)))
        shift!(vector_3)
      elseif m == vector_4[1]
        push!(AI, Arrival_Information(i,4,m,rand(LogNormal(log(2.0),sqrt(log(0.8+1)))),typemax(Float64)))
        shift!(vector_4)
      else
        push!(AI, Arrival_Information(i,5,m,rand(LogNormal(log(3.0),sqrt(log(0.5+1)))),typemax(Float64)))
        shift!(vector_5)
      end
      i += 1
    end
    return AI
  end

  # 서버별 정보를 생성해서 Server_Setting array를 리턴하는 함수
  function server_setter()
    SS = Server_Setting[]
    push!(SS, Server_Setting(5.0, 100.0, 150.0, 0.3333, 3, 3.0, 0.001, 100.0, 1000.0, (1,)))
    push!(SS, Server_Setting(7.0, 102.0, 250.0, 0.2, 3, 3.0, 0.001, 102.0, 2000.0, (1,)))
    push!(SS, Server_Setting(6.0, 99.0, 220.0, 1.0, 3, 3.0, 0.001, 99.0, 3000.0, (1,2)))
    push!(SS, Server_Setting(5.0, 105.0, 150.0, 0.6667, 3, 3.0, 0.001, 105.0, 1000.0, (1,2,3)))
    push!(SS, Server_Setting(7.0, 100.0, 300.0, 0.8, 3, 3.0, 0.001, 100.0, 2000.0, (2,3)))
    push!(SS, Server_Setting(8.0, 102.0, 350.0, 0.4, 3, 3.0, 0.001, 102.0, 3000.0, (2,3)))
    push!(SS, Server_Setting(6.0, 100.0, 220.0, 0.4286, 3, 3.0, 0.001, 100.0, 1000.0, (3,)))
    push!(SS, Server_Setting(7.0, 105.0, 350.0, 0.5, 3, 3.0, 0.001, 105.0, 2000.0, (4,5)))
    push!(SS, Server_Setting(8.0, 102.0, 400.0, 0.6, 3, 3.0, 0.001, 102.0, 3000.0, (4,5)))
    push!(SS, Server_Setting(10.0, 105.0, 700.0, 0.4444, 3, 3.0, 0.001, 105.0, 1000.0, (5,)))
    return SS
  end

  # 서버 객체를 만들어서 Server array를 리턴하는 함수
  function server_creater(SS::Array{Server_Setting}, WS::Array{Workload_Setting})
    #aggreated scv를 먼저 계산
    tempv = Float64[]
    for i in 1:length(WS)
       push!(tempv, 1/WS[i].mean_workload)
    end
    μ_min = minimum(tempv)
    denom = sum(1/WS[i].mean_inter_arrival for i in 1:length(WS))
    num = sum((1/WS[i].mean_inter_arrival)*(WS[i].std_inter_arrival/WS[i].mean_inter_arrival)^2 for i in 1:length(WS))
    agg_scv = num/denom

    #서버 객체 생성 및 초기값 설정
    S = Server[]
    for j in 1:length(SS)
      push!(S, Server(SS[j].x_0, SS[j].x_0, SS[j].p_0, SS[j].p_0))
      S[j].κ = ((-log(SS[j].ϵ)*max(1,agg_scv))/(μ_min*SS[j].δ))
      # S[j].κ = 0.0
    end
    return S
  end

  function update_buffer(vdc::VirtualDataCenter)
    for i in 1:length(vdc.WS)
      n = (vdc.buffer_update_counter) % length(vdc.SI[i].interval) + 1 # n: n^th interval of i^th workload
      vdc.WS[i].mean_inter_arrival = 1/vdc.SI[i].interval[n].λ_max # WS[i]의 mean inter arrival을 바꿈
      vdc.WS[i].std_inter_arrival = 1/vdc.SI[i].interval[n].λ_max # exponential distribution이므로, μ = σ
    end
    tempv = Float64[]
    for i in 1:length(vdc.WS)
      #push!(tempv,vdc.WS[i].mean_inter_arrival)     # 잘못되었던 부분
       push!(tempv, 1/vdc.WS[i].mean_workload)
    end
    μ_min = minimum(tempv)
    denom = sum(1/vdc.WS[i].mean_inter_arrival for i in 1:length(vdc.WS))
    num = sum((1/vdc.WS[i].mean_inter_arrival)*(vdc.WS[i].std_inter_arrival/vdc.WS[i].mean_inter_arrival)^2 for i in 1:length(vdc.WS))
#    num = sum((1/vdc.WS[i].mean_inter_arrival)*(vdc.WS[i].std_inter_arrival/vdc.WS[i].mean_inter_arrival)^2 for i in 1:length(vdc.WS))
    agg_scv = num/denom
    for j in 1:length(vdc.S)
      vdc.S[j].κ = ((-log(vdc.SS[j].ϵ)*max(1,agg_scv))/(μ_min*vdc.SS[j].δ))
    end
  end
end