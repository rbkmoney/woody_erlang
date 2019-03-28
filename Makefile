REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)
SUBMODULES = build_utils
SUBTARGETS = $(patsubst %,%/.git,$(SUBMODULES))

UTILS_PATH := build_utils
# ToDo: remove unused TEMPLATES_PATH here, when the bug
# with handling of the varriable in build_utils is fixed
TEMPLATES_PATH := .
SERVICE_NAME := woody
BUILD_IMAGE_TAG := ee0028263b7663828614e3a01764a836b4018193

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

distclean:
	$(REBAR) clean -a
	rm -rfv _build _builds _cache _steps _temp

dialyze:
	$(REBAR) dialyzer

