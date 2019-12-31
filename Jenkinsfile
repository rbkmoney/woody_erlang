#!groovy
// -*- mode: groovy -*-

def finalHook = {
  runStage('store CT logs') {
    archive '_build/test/logs/'
  }
}

build('woody_erlang', 'docker-host', finalHook) {
  checkoutRepo()
  loadBuildUtils()

  def pipeDefault
  def withWsCache
  runStage('load pipeline') {
    env.JENKINS_LIB = "build_utils/jenkins_lib"
    pipeDefault = load("${env.JENKINS_LIB}/pipeDefault.groovy")
    withWsCache = load("${env.JENKINS_LIB}/withWsCache.groovy")
  }

  pipeDefault() {
    runStage('compile') {
      withGithubPrivkey {
        sh 'make wc_compile'
      }
    }
    runStage('lint') {
      sh 'make wc_lint'
    }
    runStage('xref') {
      sh 'make wc_xref'
    }
    runStage('dialyze') {
      withGithubPrivkey {
        withWsCache("_build/test/rebar3_21.3.8.7_plt") {
          sh 'make wc_dialyze'
        }
      }
    }
    runStage('test') {
      sh "make wc_test"
    }
  }
}

