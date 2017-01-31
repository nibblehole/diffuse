.PHONY: build system

#
# Variables
#
NODE_BIN=./node_modules/.bin

SRC_DIR=./src
BUILD_DIR=./build


#
# Tasks
#
all: build


build: clean system elm css
	@echo "> Done ⚡"


clean:
	@echo "> Cleaning Build Directory"
	@rm -rf $(BUILD_DIR)


css:
	@echo "> Compiling Css"
	@$(NODE_BIN)/elm-css $(SRC_DIR)/Css/Stylesheets.elm --output $(BUILD_DIR)


elm:
	@echo "> Compiling Elm"
	@elm-make $(SRC_DIR)/App/App.elm --output $(BUILD_DIR)/application.js --yes


server:
	@echo "> Booting up web server"
	@stack build && stack exec server


system:
	@echo "> Compiling System"
	@stack build && stack exec build


#
# Watch tasks
#
watch: build
	@echo "> Watching"
	@make -j watch_elm watch_system


watch_elm:
	@watchexec -p --filter *.elm -- make elm css


watch_system:
	@watchexec -p --ignore *.elm -- make system
