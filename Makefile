REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)
SUBMODULES = build_utils
SUBTARGETS = $(patsubst %,%/.git,$(SUBMODULES))

UTILS_PATH := build_utils
# ToDo: remove unused TEMPLATES_PATH here, when the bug
# with handling of the varriable in build_utils is fixed
TEMPLATES_PATH := .
SERVICE_NAME := woody
BUILD_IMAGE_TAG := 7267e019e3c75e8e5ae5c9f2004960341733f829

CALL_W_CONTAINER := all submodules rebar-update compile xref lint test dialyze clean distclean

.PHONY: $(CALL_W_CONTAINER)

all: compile

-include $(UTILS_PATH)/make_lib/utils_container.mk

$(SUBTARGETS): %/.git: %
	git submodule update --init $<
	touch $@

submodules: $(SUBTARGETS)

rebar-update:
	$(REBAR) update

compile: submodules rebar-update
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
	$(REBAR) dialyzer

