#!groovy

def finalHook = {
  runStage('store CT logs') {
    archive '_build/test/logs/'
  }
}

build('woody_erlang', 'docker-host', finalHook) {
  checkoutRepo()
  loadBuildUtils()

  def pipeDefault
  runStage('load pipeline') {
    env.JENKINS_LIB = "build_utils/jenkins_lib"
    pipeDefault = load("${env.JENKINS_LIB}/pipeDefault.groovy")
  }

  pipeDefault() {
    runStage('compile') {
      withGithubPrivkey {
        sh 'make wc_compile'
      }
    }
    // ToDo: Uncomment the stage as soon as Elvis is in the build image!
    // runStage('lint') {
    //   sh 'make w_container_lint'
    // }
    //runStage('lint') {
    //  sh 'make wc_lint'
    //}
    runStage('xref') {
      sh 'make wc_xref'
    }
    runStage('dialyze') {
      sh 'make wc_dialyze'
    }
    runStage('test') {
      sh "make wc_test"
    }
  }
}

