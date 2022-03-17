using RiskSimulator

system = IntelligentDriverModel()
scenario = get_scenario(MERGING)
planner = setup_ast(sut=system, scenario=scenario)

search!(planner)

fail_metrics = failure_metrics(planner)
α = 0.2 # risk tolerance
risk_metrics = metrics(planner, α)
risk = overall_area(planner, α=α)