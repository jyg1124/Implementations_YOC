# Written by Yongkyu Cho.
# This code simulates G(t)/G(t)/1/PS queue under the three service rate controls: RM, SR, PSA.

using Distributions, Roots, QuadGK

# Types
type Customer # real customer
  arrival_index::Int64 # this means 'n' of the 'n^th customer'
  remaining_workload::Float64
  arrival_time::Float64 # the time of arrival
  service_beginning_time::Float64 # the time when the service begins
  completion_time::Float64 # the time when the service is completed or when this customer is leaving
  sojourn_time::Float64 # the duration from arrival to leaving
  waiting_time::Float64 # the duration from arrival to the time service begins
end

type Virtual_Customer
  time_index::Int64 # 'n' of the 'n^th virtual customer' == index of time axis. This is used when we record the sojourn time of a virtual customer.
  remaining_workload::Float64
  arrival_time::Float64
  service_beginning_time::Float64
  completion_time::Float64
  sojourn_time::Float64
  waiting_time::Float64
end

type Time_Varying_Arrival_Setting
  α::Float64
  β::Float64
  γ::Float64
  λ::Function # λ(t): arrival rate function
  Λ::Function # Λ(a,b) = ∫λ(s)ds on (a,b]: integrated arrival rate function
  string_of_distribution::String # String of base distribution
  base_distribution::Distribution # Nonstationary Non-Poisson process requires its base distribution to generate arrival times
  function Time_Varying_Arrival_Setting(_coefficients::Tuple{Float64,Float64,Float64}, _string_of_distribution::String)
    α = _coefficients[1]
    β = _coefficients[2]
    γ = _coefficients[3]
    λ = x -> α + β*sin(γ*x)
    Λ = (x,s) -> α*(s-x)-(β/γ)*(cos(γ*s)-cos(γ*x))
    string_of_distribution = _string_of_distribution
    new(α, β, γ, λ, Λ, string_of_distribution)
  end
end

type Time_Varying_Service_Setting
  control::String
  param::Float64
  param_letter::String
  μ::Function # μ(t): service_rate_function
  M::Function # ∫μ(s)ds on (a,b]: integrated_service_rate_function
  string_of_distribution::String # String of workload distribution
  workload_distribution::Distribution # each customer brings its own workload distributed by a certain distribution.
  function Time_Varying_Service_Setting(_TVAS::Time_Varying_Arrival_Setting, _control::String, _param::Float64, _string_of_distribution::String)
    control = _control
    param = _param
    if _control == "RM"
      μ = t -> _TVAS.λ(t)/_param
      M = (x,y) -> (1/_param)*_TVAS.Λ(x,y)
      param_letter = "ρ"
    elseif _control == "SR"
      μ = t -> _TVAS.λ(t) + _param*sqrt(_TVAS.λ(t))
      M = (x,y) -> QuadGK.quadgk(μ, x, y)[1]
      param_letter = "ξ"
    elseif _control == "PSA"
      μ = t -> _TVAS.λ(t) + (_TVAS.λ(t)/2)*(sqrt((_TVAS.λ(t)+_param)/_TVAS.λ(t))-1)
      M = (x,y) -> QuadGK.quadgk(μ, x, y)[1]
      param_letter = "ζ"
    end
    string_of_distribution = _string_of_distribution
    new(control, param, param_letter, μ, M, string_of_distribution)
  end
end

type Record
  T::Array{Float64} # time array
  A::Array{Int64}   # number of arrivals
  D::Array{Int64}   # number of departures
  Q::Array{Int64}   # number of customers
  W::Array{Float64} # virtual waiting times (not virtual sojourn time)
  S::Array{Float64} # virtual sojourn times
  file_sim_record::IOStream
  function Record()
    T = Float64[]
    A = Int64[]
    D = Int64[]
    Q = Int64[]
    W = Float64[]
    S = Float64[]
    new(T, A, D, Q, W, S)
  end
end

type TVGG1PS_queue
  TVAS::Time_Varying_Arrival_Setting
  TVSS::Time_Varying_Service_Setting
  WIP::Array{Customer}
  Virtual_WIP::Array{Virtual_Customer}
  number_of_customers::Int64
  number_of_virtual_customers::Int64
  regular_recording_interval::Float64
  sim_time::Float64
  next_arrival_time::Float64
  next_completion_time::Float64
  next_virtual_completion_time::Float64
  next_regular_recording::Float64
  next_completion_index::Int64
  next_virtual_completion_index::Int64
  time_index::Int64
  customer_arrival_counter::Int64
  function TVGG1PS_queue(_TVAS::Time_Varying_Arrival_Setting, _TVSS::Time_Varying_Service_Setting)
    TVAS = _TVAS
    TVSS = _TVSS
    WIP = Customer[]
    Virtual_WIP = Virtual_Customer[]
    number_of_customers = 0
    number_of_virtual_customers = 0
    regular_recording_interval = 0.0
    sim_time = 0.0
    next_arrival_time = typemax(Float64)
    next_completion_time = typemax(Float64)
    next_virtual_completion_time = typemax(Float64)
    next_regular_recording = 0.0
    next_completion_index = 0
    next_virtual_completion_index = 0
    time_index = 1
    customer_arrival_counter = 0
    new(TVAS, TVSS, WIP, Virtual_WIP, number_of_customers, number_of_virtual_customers, regular_recording_interval,
        sim_time, next_arrival_time, next_completion_time, next_virtual_completion_time,
        next_regular_recording, next_completion_index, next_virtual_completion_index, time_index, customer_arrival_counter)
  end
end

# Functions
function inverse_integrated_rate_function(_Λ::Function, _s::Float64, _val::Float64)  # Λ: integrated rate function, s: starting point
    return fzero(x -> _Λ(_s,x)-_val , _s)
end

function inverse_cdf(f::Function, val::Float64) # find inf{t>0: F(t) > val}, f: pdf
  s = 0.0 # integration start point
  t = 0.0 # integration end point
  temp = 0.0 # temporal integration value (s,t)
  sum = 0.0 # whole integration value (0.0,t)
  while sum < val
    temp = QuadGK.quadgk(f,s,t)[1] # compute ∫ s to t
    s = t # change the value of s to t
    t += 0.001 # increase the value of t by 0.001
    sum += temp # add temp to sum
  end
  return t
end

function string_to_dist(Distribution::String) # All distributions have mean 1.0.
  if Distribution == "Pareto"
    return Pareto(1+sqrt(2),2-sqrt(2))
  elseif Distribution == "Lognormal"
    return LogNormal(-log(2)/2,sqrt(log(2)))
  elseif Distribution == "Exponential"
    return Exponential(1.0)
  elseif Distribution == "Erlang"
    return Erlang(2,1/2)
  elseif Distribution == "Hyperexponential"
    return Exponential(1.0) # this is temporary
  end
end

function set_distribution(TVS::Any)
  if typeof(TVS) == Time_Varying_Arrival_Setting
    TVS.base_distribution = string_to_dist(TVS.string_of_distribution)
  elseif typeof(TVS) == Time_Varying_Service_Setting
    TVS.workload_distribution = string_to_dist(TVS.string_of_distribution)
  end
end

function generate_Hyperexponential(p1::Float64, p2::Float64, θ1::Float64, θ2::Float64)
  return rand() < p1 ? rand(Exponential(θ1)) : rand(Exponential(θ2)) # with prob. p1, return Exponential(1/λ1), with prob. p2, returen Exp(1/λ2)
end

function generate_NHNP(TVAS::Time_Varying_Arrival_Setting, T::Float64)
  if TVAS.string_of_distribution != "Hyperexponential"
    g_e = t -> 1-cdf(TVAS.base_distribution,t)/mean(TVAS.base_distribution)
    S = inverse_cdf(g_e , rand())
  	V = [ inverse_integrated_rate_function(TVAS.Λ, 0.0, S) ]
    n = 1
    while V[n] < T
      push!(V, inverse_integrated_rate_function(TVAS.Λ, V[n], rand(TVAS.base_distribution)) )
      n += 1
    end
    return V
  elseif TVAS.string_of_distribution == "Hyperexponential"
    # Hyperexponential parameters
    p1 = (5+sqrt(15))/10
    p2 = 1-p1
    θ1 = 1/(2*p1)
    θ2 = 1/(2*p2)
    g = t -> p1*(1/θ1)*exp(-(1/θ1)*t)+p2*(1/θ2)*exp(-(1/θ2)*t) # Hyperexponential pdf
    G = t -> QuadGK.quadgk(g, 0.0, t)[1] # Hyperexponential cdf
    τ = 1.0 # Hyeperexponential mean
    g_e = t -> (1-G(t))/τ # Hyperexponential equilibrium pdf
    S = inverse_cdf(g_e, rand())
    V = [ inverse_integrated_rate_function(TVAS.Λ, 0.0, S) ]
    n = 1
    while V[n] < T
      S = generate_Hyperexponential(p1,p2,θ1,θ2)
      push!(V, inverse_integrated_rate_function(TVAS.Λ, V[n], S))
      n += 1
    end
    return V
  end
end

function generate_customer_pool(TVAS::Time_Varying_Arrival_Setting, TVSS::Time_Varying_Service_Setting, T::Float64)
  if TVSS.string_of_distribution != "Hyperexponential"
    arrival_times = generate_NHNP(TVAS, T)
    Customers = Customer[]
    for i in 1:length(arrival_times)
      push!(Customers, Customer(i, rand(TVSS.workload_distribution), arrival_times[i], 0.0, typemax(Float64), 0.0, 0.0))
    end
    return Customers
  else TVSS.string_of_distribution == "Hyperexponential"
    p1 = (5+sqrt(15))/10
    p2 = 1-p1
    θ1 = 1/(2*p1)
    θ2 = 1/(2*p2)
    arrival_times = generate_NHNP(TVAS, T)
    Customers = Customer[]
    for i in 1:length(arrival_times)
      push!(Customers, Customer(i, generate_Hyperexponential(p1,p2,θ1,θ2), arrival_times[i], 0.0, typemax(Float64), 0.0, 0.0))
    end
    return Customers
  end
end

function next_event(system::TVGG1PS_queue, customer_pool::Array{Customer}, record::Record)
  if system.next_arrival_time == min(system.next_arrival_time, system.next_completion_time, system.next_virtual_completion_time, system.next_regular_recording)
    current_time = system.next_arrival_time
    # reduce workloads for each customer & virtual customer in system
    total_service_amount = 0.0
    if system.number_of_customers > 0 || system.number_of_virtual_customers > 0
      total_service_amount = system.TVSS.M(system.sim_time, current_time)
      individual_service_amount = total_service_amount/system.number_of_customers
      for customer in system.WIP
        customer.remaining_workload -= individual_service_amount # reduce workload of customers
      end
      individual_virtual_service_amount = total_service_amount/(system.number_of_customers+1)
      for virtual_customer in system.Virtual_WIP
        virtual_customer.remaining_workload -= individual_virtual_service_amount # reduce workload of virtual customers
      end
    end

    # insert a new customer in the system
    system.customer_arrival_counter += 1
    system.number_of_customers += 1
    push!(system.WIP, customer_pool[system.customer_arrival_counter])
    system.WIP[end].service_beginning_time = current_time
    # update simulational time
    system.sim_time = current_time

    # update next arrival time
    system.next_arrival_time = customer_pool[system.customer_arrival_counter+1].arrival_time

    # update next completion information
    if system.number_of_customers == 1
      system.next_completion_index = 1
      system.next_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, system.WIP[1].remaining_workload)
    elseif system.number_of_customers > 1
      if system.WIP[system.next_completion_index].remaining_workload > system.WIP[end].remaining_workload
        system.next_completion_index = system.number_of_customers
      end
      nci = system.next_completion_index
      Q = system.number_of_customers
      system.next_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, Q*system.WIP[nci].remaining_workload)
    end

    # update next virtual completion information
    if system.number_of_virtual_customers > 0
      nvci = system.next_virtual_completion_index
      Q = system.number_of_customers
      system.next_virtual_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, (Q+1)*system.Virtual_WIP[nvci].remaining_workload)
    end

    total_workload = 0.0
    for customer in system.WIP
      total_workload += customer.remaining_workload
    end
  elseif system.next_completion_time == min(system.next_arrival_time, system.next_completion_time, system.next_virtual_completion_time, system.next_regular_recording)
    current_time = system.next_completion_time
    # reduce workloads for each customer & virtual customer in system
    total_service_amount = 0.0
    if system.number_of_customers > 1 || system.number_of_virtual_customers > 0 # if # of customer == 1, we can just remove the customer
      total_service_amount = system.TVSS.M(system.sim_time, current_time)
      individual_service_amount = total_service_amount/system.number_of_customers
      for customer in system.WIP
        customer.remaining_workload -= individual_service_amount # reduce workload of customers
      end
      individual_virtual_service_amount = total_service_amount/(system.number_of_customers+1)
      for virtual_customer in system.Virtual_WIP
        virtual_customer.remaining_workload -= individual_virtual_service_amount # reduce workload of virtual customers
      end
    end

    # save completed Customer time information
    nci = system.next_completion_index
    system.WIP[nci].completion_time = current_time
    system.WIP[nci].sojourn_time = current_time - system.WIP[nci].arrival_time
    system.WIP[nci].waiting_time = 0.0

    # copy the information of the completed customer to the customer pool
    customer_pool[system.WIP[nci].arrival_index] = system.WIP[nci]

    # remove the completing customer from the system
    deleteat!(system.WIP, nci)
    system.number_of_customers -= 1

    # update simulational time
    system.sim_time = current_time

    # update next completion information
    if system.number_of_customers == 0
      system.next_completion_index = 0
      system.next_completion_time = typemax(Float64)
    elseif system.number_of_customers == 1
      system.next_completion_index = 1
      system.next_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, system.WIP[1].remaining_workload)
    elseif system.number_of_customers > 1
      shortest_remaining_workload = typemax(Float64)
      for i in 1:length(system.WIP)
        if shortest_remaining_workload > system.WIP[i].remaining_workload
          shortest_remaining_workload = system.WIP[i].remaining_workload
          system.next_completion_index = i
        end
      end
      nci = system.next_completion_index
      Q = system.number_of_customers
      system.next_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, Q*system.WIP[nci].remaining_workload)
    end

    # update next virtual completion information
    if system.number_of_virtual_customers > 0
      nvci = system.next_virtual_completion_index
      Q = system.number_of_customers
      system.next_virtual_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, (Q+1)*system.Virtual_WIP[nvci].remaining_workload)
    end
  elseif system.next_virtual_completion_time == min(system.next_arrival_time, system.next_completion_time, system.next_virtual_completion_time, system.next_regular_recording)
    current_time = system.next_virtual_completion_time
    # reduce workloads for each customer & virtual customer in system
    total_service_amount = 0.0
    if system.number_of_customers > 0 || system.number_of_virtual_customers > 1
      total_service_amount = system.TVSS.M(system.sim_time, current_time)
      individual_service_amount = total_service_amount/system.number_of_customers
      for customer in system.WIP
        customer.remaining_workload -= individual_service_amount # reduce workload of customers
      end
      individual_virtual_service_amount = total_service_amount/(system.number_of_customers+1)
      for virtual_customer in system.Virtual_WIP
        virtual_customer.remaining_workload -= individual_virtual_service_amount # reduce workload of virtual customers
      end
    end

    # Record the virtual sojourn time
    nvci = system.next_virtual_completion_index
    record.S[system.Virtual_WIP[nvci].time_index] = current_time - system.Virtual_WIP[nvci].arrival_time
    sojourn_time = record.S[system.Virtual_WIP[nvci].time_index]

    # remove the completing virtual customer from the system
    deleteat!(system.Virtual_WIP, system.next_virtual_completion_index)
    system.number_of_virtual_customers -= 1

    # update simulational time
    system.sim_time = current_time

    # update next virtual completion information
    if system.number_of_virtual_customers == 0
      system.next_virtual_completion_index = 0
      system.next_virtual_completion_time = typemax(Float64)
    elseif system.number_of_virtual_customers == 1
      system.next_virtual_completion_index = 1
      Q = system.number_of_customers
      system.next_virtual_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, (Q+1)*system.Virtual_WIP[1].remaining_workload)
    elseif system.number_of_virtual_customers > 1
      shortest_remaining_workload = typemax(Float64)
      for i in 1:length(system.Virtual_WIP)
        if shortest_remaining_workload > system.Virtual_WIP[i].remaining_workload
          shortest_remaining_workload = system.Virtual_WIP[i].remaining_workload
          system.next_virtual_completion_index = i
        end
      end
      nvci = system.next_virtual_completion_index
      Q = system.number_of_customers
      system.next_virtual_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, (Q+1)*system.Virtual_WIP[nvci].remaining_workload)
    end

  elseif system.next_regular_recording == min(system.next_arrival_time, system.next_completion_time, system.next_virtual_completion_time, system.next_regular_recording)
    current_time = system.next_regular_recording
    # reduce workloads for each customer & virtual customer in system
    total_service_amount = 0.0
    if system.number_of_customers > 0 || system.number_of_virtual_customers > 0
      total_service_amount = system.TVSS.M(system.sim_time, current_time)
      individual_service_amount = total_service_amount/system.number_of_customers
      for customer in system.WIP
        customer.remaining_workload -= individual_service_amount # reduce workload of customers
      end
      individual_virtual_service_amount = total_service_amount/(system.number_of_customers+1)
      for virtual_customer in system.Virtual_WIP
        virtual_customer.remaining_workload -= individual_virtual_service_amount # reduce workload of virtual customers
      end
    end

    # insert a new virtual customer in the system
    if system.TVSS.string_of_distribution != "Hyperexponential"
      push!(system.Virtual_WIP, Virtual_Customer(system.time_index, rand(system.TVSS.workload_distribution), current_time, current_time, typemax(Float64), 0.0, 0.0))
    elseif system.TVSS.string_of_distribution == "Hyperexponential"
      p1 = (5+sqrt(15))/10
      p2 = 1-p1
      θ1 = 1/(2*p1)
      θ2 = 1/(2*p2)
      push!(system.Virtual_WIP, Virtual_Customer(system.time_index, generate_Hyperexponential(p1,p2,θ1,θ2), current_time, current_time, typemax(Float64), 0.0, 0.0))
    end

    # increase # of virtual customer
    system.number_of_virtual_customers += 1

    # update simulational time & increase time index
    system.sim_time = current_time
    system.time_index += 1

    # update next regular recording time
    system.next_regular_recording += system.regular_recording_interval

    # update next virtual completion info
    if system.number_of_virtual_customers == 1
      system.next_virtual_completion_index = 1
      Q = system.number_of_customers
      system.next_virtual_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, (Q+1)*system.Virtual_WIP[1].remaining_workload)
    else
      nvci = system.next_virtual_completion_index
      if system.Virtual_WIP[nvci].remaining_workload > system.Virtual_WIP[end].remaining_workload
        system.next_virtual_completion_index = system.number_of_virtual_customers
      end
      nvci = system.next_virtual_completion_index
      Q = system.number_of_customers
      system.next_virtual_completion_time = inverse_integrated_rate_function(system.TVSS.M, system.sim_time, (Q+1)*system.Virtual_WIP[nvci].remaining_workload)
    end

    # record the number of customer, arrival process, temporal sojourn time
    push!(record.Q, system.number_of_customers)
    push!(record.A, system.customer_arrival_counter)
    push!(record.S, 0.0) # this will be re-recorded when the virtual customer is leaving
  end
end

function run_to_end(system::TVGG1PS_queue, customer_pool::Array{Customer}, record::Record, T::Float64, warm_up_time::Float64)
  while system.sim_time < T
    next_event(system, customer_pool, record)
  end
end

function do_experiment(queue::String, control::String, param::Float64, arrival::String, service::String, coeff::Tuple, T::Float64, N::Int64, record::Record)
  TVAS = Time_Varying_Arrival_Setting(coeff, arrival)
  TVSS = Time_Varying_Service_Setting(TVAS, control, param, service)
  set_distribution(TVAS)
  set_distribution(TVSS)
  file_num_in_queue = open("num in queue ($queue, gamma $(coeff[3]), control $control, param $param, arrival $arrival, service $service, time $T, rep $N).txt" , "w")
  file_virtual_waiting_time = open("virtual waiting time ($queue, gamma $(coeff[3]), control $control, param $param, arrival $arrival, service $service, time $T, rep $N).txt" , "w")
  regular_recording_interval = T/1000
  t = 0.0
  while t <= T
		push!(record.T, t)
    t += regular_recording_interval
  end
	writedlm(file_num_in_queue, transpose(record.T)) # write time-axis
  writedlm(file_virtual_waiting_time, transpose(record.T)) # write time-axis

  for n in 1:N
    println("Replication $n")
		record.Q = Int64[]
    record.S = Float64[]
    record.A = Int64[]
    system = TVGG1PS_queue(TVAS, TVSS)
    customer_pool = generate_customer_pool(TVAS, TVSS, T*1.1)
    system.regular_recording_interval = T/1000
    system.next_arrival_time = customer_pool[1].arrival_time
    run_to_end(system, customer_pool, record, T*1.1, 0.0)
    writedlm(file_num_in_queue, transpose(record.Q)) # write record Q(t)
    writedlm(file_virtual_waiting_time, transpose(record.S)) # write record W(t)
	end
  close(file_num_in_queue)
  close(file_virtual_waiting_time)
end

# main
queue = "TVGG1PS"
control = "PSA"
param = 1.0
arrival = "Hyperexponential"
service = "Hyperexponential"
coeff = (1.0, 0.2, 0.001)
T = 20000.0
N = 10000
record = Record()
do_experiment(queue, control, param, arrival, service, coeff, T, N, record)
