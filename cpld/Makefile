PROJECT = samx4

.PHONY: all
all:
	@echo "This Makefile currently exists only to provide 'make clean'"
	@echo "Please build this project using ISE."

###

CLEAN =

###

# Some of this should probably be moved to distclean target

CLEAN += \
        $(PROJECT).bld \
        $(PROJECT).cmd_log \
        $(PROJECT).gise \
        $(PROJECT).gyd \
        $(PROJECT).jed \
        $(PROJECT).lso \
        $(PROJECT).mfd \
        $(PROJECT).nga \
        $(PROJECT).ngc \
        $(PROJECT).ngd \
        $(PROJECT).ngr \
        $(PROJECT).pad \
        $(PROJECT).pnx \
        $(PROJECT).prj \
        $(PROJECT).rpt \
        $(PROJECT).stx \
        $(PROJECT).syr \
        $(PROJECT).tim \
        $(PROJECT).tspec \
        $(PROJECT).vm6 \
        $(PROJECT).xml \
        $(PROJECT).xst \
        $(PROJECT)_build.xml \
        $(PROJECT)_envsettings.html \
        $(PROJECT)_ngdbuild.xrpt \
        $(PROJECT)_pad.csv \
        $(PROJECT)_summary.html \
        $(PROJECT)_xst.xrpt \
        tmperr.err \
        webtalk_pn.xml

.PHONY: clean
clean:
	test -d "_ngo" && rm -rf "_ngo" || true
	test -d "_xmsgs" && rm -rf "_xmsgs" || true
	test -d "iseconfig" && rm -rf "iseconfig" || true
	test -d "$(PROJECT)_html" && rm -rf "$(PROJECT)_html" || true
	test -d "xlnx_auto_0_xdb" && rm -rf "xlnx_auto_0_xdb" || true
	test -d "xst" && rm -rf "xst" || true
	rm -f $(CLEAN)

.PHONY: clena
clena: clean
	@echo "How much clena do you want it?"

.PHONY: distclean
distclean: clean
