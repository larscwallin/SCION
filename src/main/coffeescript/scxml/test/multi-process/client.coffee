#how this works:
#request initial test from server
#start scxml test client
#run through test script
#when we're done, send results to server, and request new test
define ["util/BufferedStream","util/set/ArraySet","util/utils",'util/memory','scxml/async-for',"child_process",'fs','util'],(BufferedStream,Set,utils,memoryUtil,asyncForEach,child_process,fs,util) ->

	(eventDensity,projectDir,numberOfIterationsPerTest) ->
		SCXML_MODULE = "scxml/test/multi-process/scxml"

		numberOfIterationsPerTest = parseInt numberOfIterationsPerTest

		console.error "Starting client. Received args eventDensity #{eventDensity}, projectDir #{projectDir}, numberOfIterationsPerTest #{numberOfIterationsPerTest}."

		wl = utils.wrapLine process.stdout.write,process.stdout

		#state variables
		currentTest = null
		currentScxmlProcess = null
		expectedConfigurations = null
		eventsToSend = null
		scxmlWL = null
		memory = null
		startTime = null
		initializationTime = null
		finishTime = null

		aggregateStats = null
		nextStep = errBack = failBack = null

		postTestResults = (testId,passOrFail) ->
			wl(
				method:"post-results"
				testId:testId
				stats:aggregateStats
				pass : passOrFail	#aggregate pass or fail
			)

		pushAggregateStats = (passOrFail,msg) ->
			aggregateStats.push
				pass : passOrFail
				msg : msg
				initializationTime : initializationTime - startTime
				elapsedTime : finishTime - initializationTime
				totalElapsedTime : finishTime - startTime	#for convenience
				memory : memory

		runTest = (jsonTest) ->
			#hook up state variables
			expectedConfigurations =
				[new Set currentTest.testScript.initialConfiguration].concat(
					(new Set eventTuple.nextConfiguration for eventTuple in currentTest.testScript.events))

			console.error "received test #{currentTest.id}"
			
			#start up a new statechart process
			currentScxmlProcess = child_process.spawn "bash",["#{projectDir}/bin/run-module.sh",SCXML_MODULE,currentTest.interpreter]

			scxmlWL = utils.wrapLine currentScxmlProcess.stdin.write,currentScxmlProcess.stdin

			startTime = new Date()
			memory = []

			#hook up messaging
			scOutStream = new BufferedStream currentScxmlProcess.stdout
			scOutStream.on "line",(l) -> processClientMessage JSON.parse l

			currentScxmlProcess.stderr.setEncoding 'utf8'
			currentScxmlProcess.stderr.on 'data',(s) ->
				console.error 'from statechart stderr',s

			scxmlWL currentTest
				
		sendEvents = ->
			e = eventsToSend.shift()
			if e
				console.error "sending event",e.event.name

				step = ->
					currentScxmlProcess.stdin.write "#{e.event.name}\n"
					setTimeout sendEvents,eventDensity

				if e.after then setTimeout step,e.after else step()

		processClientMessage = (jsonMessage) ->
			switch jsonMessage.method
				when "statechart-initialized"
					memory.push memoryUtil.getMemory currentScxmlProcess.pid

					initializationTime = new Date()

					#start to send events into sc process
					eventsToSend = currentTest.testScript.events.slice()

					console.error 'statechart in child process initialized.'
					console.error "sending events #{JSON.stringify eventsToSend}"
					sendEvents()

				when "check-configuration"
					console.error "received request to check configuration"

					expectedConfiguration = expectedConfigurations.shift()

					configuration =  new Set jsonMessage.configuration

					console.error "Expected configuration",expectedConfiguration
					console.error "Received configuration",configuration
					console.error "Remaining expected configurations",expectedConfigurations
						
					if expectedConfiguration.equals configuration
						console.error "Matched expected configuration."

						#if we're out of tests, then we're done and we report that we succeeded
						if not expectedConfigurations.length

							#check memory usage
							memory.push memoryUtil.getMemory currentScxmlProcess.pid
							finishTime = new Date()

							pushAggregateStats true

							#we're done, post results and send signal to fetch next test
							currentScxmlProcess.on 'exit',->
								currentScxmlProcess.removeAllListeners()
								nextStep()

							#close the pipe, which will terminate the process
							currentScxmlProcess.stdin.end()
							
					else
						#test has failed
						msg = "Did not match expected configuration. Received: #{JSON.stringify(configuration)}. Expected:#{JSON.stringify(expectedConfiguration)}."
						
						#prevent sending further events
						eventsToSend = []

						#check memory usage
						memory.push memoryUtil.getMemory currentScxmlProcess.pid
						finishTime = new Date()

						pushAggregateStats false,msg

						currentScxmlProcess.on 'exit',->
							#clear event listeners
							currentScxmlProcess.removeAllListeners()
							#report failed test
							failBack()

						#close the pipe, which will terminate the process
						currentScxmlProcess.stdin.end()


				when "set-timeout"
					setTimeout (-> scxmlWL jsonMessage.event),jsonMessage.timeout
				when "log"
					console.error "from statechart process:",jsonMessage.args
				when "debug"
					console.error "from statechart process:",jsonMessage.args
				else
					console.error "received unknown method:",jsonMessage.method
					

		inStream = new BufferedStream process.stdin
		inStream.on "line",(l) ->
			currentTest = JSON.parse l
			aggregateStats = []

			testIterations = [0...numberOfIterationsPerTest]
			console.error "starting test #{currentTest.id} with iterations:",testIterations

			#TODO: accumulate aggregate results in some data structure so we can post them here
			asyncForEach(
				testIterations,
				( (l,ns,eb,fb) ->
					nextStep = ns
					errBack = eb
					failBack = fb
					runTest currentTest
				),
				(->
					console.error "Done. Posting results."
					postTestResults currentTest.id,true),
				(->),
				(-> postTestResults currentTest.id,false)
			)

		process.stdin.resume()
