.PHONY: preflight reference compile sim mat_add partial_block mat_mul divergence bank_conflict zero_thread verdi clean

preflight:
	python3 scripts/preflight.py

reference:
	python3 scripts/reference_iss.py

compile:
	bash scripts/run_vcs.sh all

sim:
	bash scripts/run_vcs.sh all

mat_add:
	bash scripts/run_vcs.sh mat_add

partial_block:
	bash scripts/run_vcs.sh partial_block

mat_mul:
	bash scripts/run_vcs.sh mat_mul

divergence:
	bash scripts/run_vcs.sh divergence

bank_conflict:
	bash scripts/run_vcs.sh bank_conflict

zero_thread:
	bash scripts/run_vcs.sh zero_thread

verdi:
	bash scripts/open_verdi.sh

clean:
	rm -rf build/simv build/simv.daidir
	find build logs waves -mindepth 1 -maxdepth 1 -type f -delete

# M2 control-plane verification (independent of Legacy gpu_top).
M2_CONTEXTS ?= 4
M2_WG_THREADS ?= 64
M2_REQUIRE_FSDB ?= 1
SCENARIO ?= 1
.PHONY: m2_env m2 m2_scenario m2_vcs_matrix m2_verdi m2_scenario_verdi m2_iverilog m2_matrix m1_verilator
m2_env:
	bash scripts/check_m2_env.sh
m2:
	M2_REQUIRE_FSDB=$(M2_REQUIRE_FSDB) bash scripts/run_m2_vcs.sh $(M2_CONTEXTS) $(M2_WG_THREADS) 0
m2_scenario:
	M2_REQUIRE_FSDB=$(M2_REQUIRE_FSDB) bash scripts/run_m2_vcs.sh $(M2_CONTEXTS) $(M2_WG_THREADS) $(SCENARIO)
m2_vcs_matrix:
	M2_REQUIRE_FSDB=$(M2_REQUIRE_FSDB) bash scripts/run_m2_vcs_matrix.sh
m2_verdi:
	bash scripts/open_m2_verdi.sh $(M2_CONTEXTS) $(M2_WG_THREADS) 0
m2_scenario_verdi:
	bash scripts/open_m2_verdi.sh $(M2_CONTEXTS) $(M2_WG_THREADS) $(SCENARIO)
m2_iverilog:
	python3 scripts/run_m2_iverilog.py
m2_matrix:
	python3 scripts/run_m2_iverilog.py --matrix
m1_verilator:
	python3 scripts/run_m1_verilator.py
