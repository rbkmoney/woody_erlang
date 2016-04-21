REBAR := $(shell which rebar3 2>/dev/null || which ./rebar3)

.PHONY: all compile test clean distclean dialyze

all: compile

compile:
	$(REBAR) compile

rebar-update:
	$(REBAR) update

test:
	$(REBAR) ct

xref:
	$(REBAR) xref

clean:
	$(REBAR) clean

distclean:
	$(REBAR) clean -a
	rm -rfv _build _builds _cache _steps _temp

dialyze:
	$(REBAR) dialyzer
