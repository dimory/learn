.PHONY: preflight reference compile sim mat_add partial_block mat_mul divergence bank_conflict zero_thread verdi clean

preflight:
	python3 scripts/preflight.py

reference:
	python3 scripts/reference_iss.py

compile:
	./scripts/run_vcs.sh all

sim:
	./scripts/run_vcs.sh all

mat_add:
	./scripts/run_vcs.sh mat_add

partial_block:
	./scripts/run_vcs.sh partial_block

mat_mul:
	./scripts/run_vcs.sh mat_mul

divergence:
	./scripts/run_vcs.sh divergence

bank_conflict:
	./scripts/run_vcs.sh bank_conflict

zero_thread:
	./scripts/run_vcs.sh zero_thread

verdi:
	./scripts/open_verdi.sh

clean:
	rm -rf build/simv build/simv.daidir
	find build logs waves -mindepth 1 -maxdepth 1 -type f -delete

# M2 control-plane verification (independent of Legacy gpu_top).
.PHONY: m2 m2_vcs_matrix m2_verdi m2_iverilog m2_matrix m1_verilator
m2:
	./scripts/run_m2_vcs.sh
m2_vcs_matrix:
	./scripts/run_m2_vcs_matrix.sh
m2_verdi:
	./scripts/open_m2_verdi.sh
m2_iverilog:
	python3 scripts/run_m2_iverilog.py
m2_matrix:
	python3 scripts/run_m2_iverilog.py --matrix
m1_verilator:
	python3 scripts/run_m1_verilator.py
