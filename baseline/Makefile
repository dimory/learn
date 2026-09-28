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
	find build logs waves -mindepth 1 -maxdepth 1 -type f -delete
