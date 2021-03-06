REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)
SUBMODULES = build_utils
SUBTARGETS = $(patsubst %,%/.git,$(SUBMODULES))

UTILS_PATH := build_utils
# ToDo: remove unused TEMPLATES_PATH here, when the bug
# with handling of the varriable in build_utils is fixed
TEMPLATES_PATH := .
SERVICE_NAME := woody

BUILD_IMAGE_NAME := build-erlang
BUILD_IMAGE_TAG := c60896ef07d41e7ae2e5f9b6ce845a60ad79acc7

CALL_W_CONTAINER := all submodules compile xref lint test bench dialyze clean distclean \
	check_format format

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

check_format:
	$(REBAR) fmt -c

format:
	$(REBAR) fmt -w

clean:
	$(REBAR) clean
	$(REBAR) as test clean
	$(REBAR) as prod clean

distclean:
	rm -rf test/woody_test_thrift.?rl test/.rebar3
	rm -rfv _build

dialyze:
	$(REBAR) as test dialyzer

bench:
	$(REBAR) as test bench -m bench_woody_event_handler -n 1000
	$(REBAR) as test bench -m bench_woody_formatter -n 10
	erl -pa _build/test/lib/*/ebin _build/test/lib/woody/test -noshell \
		-s benchmark_memory_pressure run \
		-s erlang halt
