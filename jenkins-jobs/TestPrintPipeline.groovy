// Avoid Jenkins / Hudson core APIs here — they require Script Security approval on a new controller.

pipelineJob('TestPrintPipeline') {
    logRotator(32, -1, -1, -1)

    definition {
        cps {
            script('''\
pipeline {
    agent any
    stages {
        stage('Test') {
            steps {
                echo 'Hello, World!'
            }
        }
    }
}
'''.stripIndent())
        }
    }
}
