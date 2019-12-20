REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)
SUBMODULES = build_utils
SUBTARGETS = $(patsubst %,%/.git,$(SUBMODULES))

UTILS_PATH := build_utils
# ToDo: remove unused TEMPLATES_PATH here, when the bug
# with handling of the varriable in build_utils is fixed
TEMPLATES_PATH := .
SERVICE_NAME := woody
BUILD_IMAGE_TAG := cd38c35976f3684fe7552533b6175a4c3460e88b

CALL_W_CONTAINER := all submodules rebar-update compile xref lint test dialyze clean distclean

.PHONY: $(CALL_W_CONTAINER)

all: compile

-include $(UTILS_PATH)/make_lib/utils_container.mk

$(SUBTARGETS): %/.git: %
	git submodule update --init $<
	touch $@

submodules: $(SUBTARGETS)

compile: submodules
	$(REBAR) compile

test: submodules
	$(REBAR) eunit
	$(REBAR) ct

xref: submodules
	$(REBAR) xref

lint: compile
	elvis rock

clean:
	$(REBAR) clean
	$(REBAR) as test clean
	$(REBAR) as prod clean

distclean:
	$(REBAR) clean -a
	$(REBAR) as test clean -a
	$(REBAR) as prod clean -a
	rm -rfv _build _builds _cache _steps _temp

dialyze:
	$(REBAR) as test dialyzer

bench:
	$(REBAR) as test bench -m bench_woody_event_handler -n 1000
	$(REBAR) as test bench -m bench_woody_formatter -n 10
	erl -pa _build/test/lib/*/ebin _build/test/lib/woody/test -noshell \
		-s benchmark_memory_pressure run \
		-s erlang halt
