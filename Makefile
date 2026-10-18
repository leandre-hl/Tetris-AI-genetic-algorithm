# Build the Tetris genetic algorithm in bytecode with ocamlc.
# Requirements: OCaml 5 or later (the code uses Domain and Atomic).
# No external library is needed.

OCAMLC = ocamlc

# -I src   : lets bin/main.ml and src/genetic.ml find the compiled interfaces
#            of the modules in src/ (Tetris, Genetic)
# -I +unix : location of the Unix library (OCaml 5 and later)
FLAGS  = -w +a-4-9-40-41-42-44-45-70 -I src -I +unix
LIBS   = unix.cma

.PHONY: all run clean

all: main

# Compile one .ml file to .cmo (+ .cmi) next to the source file.
src/%.cmo: src/%.ml
	$(OCAMLC) $(FLAGS) -c $<

bin/%.cmo: bin/%.ml
	$(OCAMLC) $(FLAGS) -c $<

# Dependencies between modules (compilation order).
src/genetic.cmo: src/tetris.cmo
bin/main.cmo: src/genetic.cmo

# Link: libraries first, then the modules, dependencies first.
main: src/tetris.cmo src/genetic.cmo bin/main.cmo
	$(OCAMLC) $(FLAGS) $(LIBS) $^ -o $@

run: main
	./main

clean:
	rm -f main src/*.cmi src/*.cmo bin/*.cmi bin/*.cmo