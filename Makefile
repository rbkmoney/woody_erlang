REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)
ORG_NAME := rbkmoney

# Note: RELNAME should match the name of
# the first service in docker-compose.yml
RELNAME := dev
BASE_IMAGE := "$(ORG_NAME)/build:latest"

CALL_ANYWHERE := rebar-update compile xref lint test dialyze clean distclean

CALL_W_CONTAINER := $(CALL_ANYWHERE)

include utils.mk

.PHONY: $(CALL_W_CONTAINER) all $(UTIL_TARGETS)


.PHONY: all compile test clean distclean dialyze

all: compile

rebar-update:
	$(REBAR) update

compile: rebar-update
	$(REBAR) compile

test:
	$(REBAR) ct

xref:
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

