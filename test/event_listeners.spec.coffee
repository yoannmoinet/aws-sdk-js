helpers = require('./helpers')
AWS = helpers.AWS
MockService = helpers.MockService

describe 'AWS.EventListeners', ->

  oldSetTimeout = setTimeout
  config = null; service = null; totalWaited = null; delays = []
  successHandler = null; errorHandler = null; completeHandler = null
  retryHandler = null

  beforeEach ->
    # Mock the timer manually (jasmine.Clock does not work in node)
    `setTimeout = jasmine.createSpy('setTimeout');`
    setTimeout.andCallFake (callback, delay) ->
      totalWaited += delay
      delays.push(delay)
      callback()

    totalWaited = 0
    delays = []
    service = new MockService(maxRetries: 3)
    service.config.credentials = AWS.util.copy(service.config.credentials)

    # Helpful handlers
    successHandler = jasmine.createSpy('success')
    errorHandler = jasmine.createSpy('error')
    completeHandler = jasmine.createSpy('complete')
    retryHandler = jasmine.createSpy('retry')

  # Safely tear down setTimeout hack
  afterEach -> `setTimeout = oldSetTimeout`

  makeRequest = (callback) ->
    request = service.makeRequest('mockMethod', foo: 'bar')
    request.on('retry', retryHandler)
    request.on('error', errorHandler)
    request.on('success', successHandler)
    request.on('complete', completeHandler)
    if callback
      request.send(callback)
    else
      request

  describe 'validate', ->
    it 'takes the request object as a parameter', ->
      request = makeRequest()
      request.on 'validate', (req) ->
        expect(req).toBe(request)
        throw "ERROR"
      response = request.send(->)
      expect(response.error).toEqual("ERROR")

    it 'sends error event if credentials are not set', ->
      service.config.credentialProvider = null
      service.config.credentials.accessKeyId = null
      makeRequest(->)

      expect(errorHandler).toHaveBeenCalled()
      AWS.util.arrayEach errorHandler.calls, (call) ->
        expect(call.args[0] instanceof Error).toBeTruthy()
        expect(call.args[0].code).toEqual('CredentialsError')
        expect(call.args[0].message).toMatch(/Missing credentials/)

    it 'sends error event if credentials are not set', ->
      service.config.credentials.accessKeyId = 'akid'
      service.config.credentials.secretAccessKey = null
      makeRequest(->)

      expect(errorHandler).toHaveBeenCalled()
      AWS.util.arrayEach errorHandler.calls, (call) ->
        expect(call.args[0] instanceof Error).toBeTruthy()
        expect(call.args[0].code).toEqual('CredentialsError')
        expect(call.args[0].message).toMatch(/Missing credentials/)

    it 'does not validate credentials if request is not signed', ->
      helpers.mockHttpResponse 200, {}, ''
      service.api = new AWS.Model.Api metadata:
        endpointPrefix: 'mockservice'
        signatureVersion: null
      request = makeRequest()
      request.send(->)
      expect(errorHandler).not.toHaveBeenCalled()
      expect(successHandler).toHaveBeenCalled()

    it 'sends error event if region is not set', ->
      service.config.region = null
      request = makeRequest(->)

      call = errorHandler.calls[0]
      expect(errorHandler).toHaveBeenCalled()
      expect(call.args[0] instanceof Error).toBeTruthy()
      expect(call.args[0].code).toEqual('SigningError')
      expect(call.args[0].message).toMatch(/Missing region in config/)

    it 'ignores region validation if service has global endpoint', ->
      helpers.mockHttpResponse 200, {}, ''
      service.config.region = null
      service.isGlobalEndpoint = true

      makeRequest(->)
      expect(errorHandler).not.toHaveBeenCalled()
      delete service.isGlobalEndpoint

  describe 'build', ->
    it 'takes the request object as a parameter', ->
      request = makeRequest()
      request.on 'build', (req) ->
        expect(req).toBe(request)
        throw "ERROR"
      response = request.send(->)
      expect(response.error).toEqual("ERROR")

  describe 'afterBuild', ->
    sendRequest = (body) ->
      request = makeRequest()
      request.removeAllListeners('sign')
      request.on('build', (req) -> req.httpRequest.body = body)
      request.build()
      request

    contentLength = (body) ->
      sendRequest(body).httpRequest.headers['Content-Length']

    it 'builds Content-Length in the request headers for string content', ->
      expect(contentLength('FOOBAR')).toEqual(6)

    it 'builds Content-Length for string "0"', ->
      expect(contentLength('0')).toEqual(1)

    it 'builds Content-Length for utf-8 string body', ->
      expect(contentLength('tï№')).toEqual(6)

    it 'builds Content-Length for buffer body', ->
      expect(contentLength(new AWS.util.Buffer('tï№'))).toEqual(6)

    if AWS.util.isNode()
      it 'builds Content-Length for file body', ->
        fs = require('fs')
        file = fs.createReadStream(__filename)
        fileLen = fs.lstatSync(file.path).size
        expect(contentLength(file)).toEqual(fileLen)

  describe 'sign', ->
    it 'takes the request object as a parameter', ->
      request = makeRequest()
      request.on 'sign', (req) ->
        expect(req).toBe(request)
        throw "ERROR"
      response = request.send(->)
      expect(response.error).toEqual("ERROR")

    it 'uses the api.signingName if provided', ->
      service.api.signingName = 'SIGNING_NAME'
      spyOn(AWS.Signers.RequestSigner, 'getVersion').andCallFake ->
        (req, signingName) -> throw signingName
      request = makeRequest()
      response = request.send(->)
      expect(response.error).toEqual('SIGNING_NAME')
      delete service.api.signingName

    it 'uses the api.endpointPrefix if signingName not provided', ->
      spyOn(AWS.Signers.RequestSigner, 'getVersion').andCallFake ->
        (req, signingName) -> throw signingName
      request = makeRequest()
      response = request.send(->)
      expect(response.error).toEqual('mockservice')

  describe 'send', ->
    it 'passes httpOptions from config', ->
      options = {}
      spyOn(AWS.HttpClient, 'getInstance').andReturn handleRequest: (req, opts) ->
        options = opts
        new AWS.SequentialExecutor()
      service.config.httpOptions = timeout: 15
      service.config.maxRetries = 0
      makeRequest(->)
      expect(options.timeout).toEqual(15)

    it 'signs only once in normal case', ->
      signHandler = jasmine.createSpy('sign')
      helpers.mockHttpResponse 200, {}, ['data']

      request = makeRequest()
      request.on('sign', signHandler)
      request.build()
      request.signedAt = new Date(request.signedAt - 60 * 5 * 1000)
      request.send()
      expect(signHandler.callCount).toEqual(1)

    it 'resigns if it took more than 10 min to get to send', ->
      signHandler = jasmine.createSpy('sign')
      helpers.mockHttpResponse 200, {}, ['data']

      request = makeRequest()
      request.on('sign', signHandler)
      request.build()
      request.signedAt = new Date(request.signedAt - 60 * 12 * 1000)
      request.send()
      expect(signHandler.callCount).toEqual(2)

  describe 'httpData', ->
    beforeEach ->
      helpers.mockHttpResponse 200, {}, ['FOO', 'BAR', 'BAZ', 'QUX']

    it 'emits httpData event on each chunk', ->
      calls = []

      # register httpData event
      request = makeRequest()
      request.on('httpData', (chunk) -> calls.push(chunk.toString()))
      request.send()

      expect(calls).toEqual(['FOO', 'BAR', 'BAZ', 'QUX'])

    it 'does not clear default httpData event if another is added', ->
      request = makeRequest()
      request.on('httpData', ->)
      response = request.send()

      expect(response.httpResponse.body.toString()).toEqual('FOOBARBAZQUX')

  if AWS.util.isNode() and AWS.HttpClient.streamsApiVersion > 1
    describe 'httpDownloadProgress', ->
      beforeEach ->
        helpers.mockHttpResponse 200, {'content-length': 12}, ['FOO', 'BAR', 'BAZ', 'QUX']

      it 'emits httpDownloadProgress for each chunk', ->
        progress = []

        # register httpData event
        request = makeRequest()
        request.on('httpDownloadProgress', (p) -> progress.push(p))
        request.send()

        expect(progress[0]).toEqual(loaded: 3, total: 12)
        expect(progress[1]).toEqual(loaded: 6, total: 12)
        expect(progress[2]).toEqual(loaded: 9, total: 12)
        expect(progress[3]).toEqual(loaded: 12, total: 12)

  describe 'retry', ->
    it 'retries a request with a set maximum retries', ->
      sendHandler = jasmine.createSpy('send')
      service.config.maxRetries = 10

      # fail every request with a fake networking error
      helpers.mockHttpResponse
        code: 'NetworkingError', message: 'Cannot connect'

      request = makeRequest()
      request.on('send', sendHandler)
      response = request.send(->)

      expect(retryHandler).toHaveBeenCalled()
      expect(errorHandler).toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()
      expect(successHandler).not.toHaveBeenCalled()
      expect(response.retryCount).toEqual(service.config.maxRetries);
      expect(sendHandler.calls.length).toEqual(service.config.maxRetries + 1)

    it 'retries with falloff', ->
      helpers.mockHttpResponse
        code: 'NetworkingError', message: 'Cannot connect'
      makeRequest(->)
      expect(delays).toEqual([30, 60, 120])

    it 'uses retry from error.retryDelay property', ->
      helpers.mockHttpResponse
        code: 'NetworkingError', message: 'Cannot connect'
      request = makeRequest()
      request.on 'retry', (resp) -> resp.error.retryDelay = 17
      response = request.send(->)
      expect(delays).toEqual([17, 17, 17])

    it 'retries if status code is >= 500', ->
      helpers.mockHttpResponse 500, {}, ''

      makeRequest (err) ->
        expect(err.code).toEqual 500
        expect(err.message).toEqual(null)
        expect(err.statusCode).toEqual(500)
        expect(err.retryable).toEqual(true)
        expect(@retryCount).
          toEqual(service.config.maxRetries)

    it 'should not emit error if retried fewer than maxRetries', ->
      helpers.mockIntermittentFailureResponse 2, 200, {}, 'foo'

      response = makeRequest(->)

      expect(totalWaited).toEqual(90)
      expect(response.retryCount).toBeLessThan(service.config.maxRetries)
      expect(response.data).toEqual('foo')
      expect(errorHandler).not.toHaveBeenCalled()

    ['ExpiredToken', 'ExpiredTokenException', 'RequestExpired'].forEach (name) ->
      it 'invalidates expired credentials and retries', ->
        spyOn(AWS.HttpClient, 'getInstance')
        AWS.HttpClient.getInstance.andReturn handleRequest: (req, opts, cb, errCb) ->
          if req.headers.Authorization.match('Credential=INVALIDKEY')
            helpers.mockHttpSuccessfulResponse 403, {}, name, cb
          else
            helpers.mockHttpSuccessfulResponse 200, {}, 'DATA', cb
          new AWS.SequentialExecutor()

        creds =
          numCalls: 0
          expired: false
          accessKeyId: 'INVALIDKEY'
          secretAccessKey: 'INVALIDSECRET'
          get: (cb) ->
            if @expired
              @numCalls += 1
              @expired = false
              @accessKeyId = 'VALIDKEY' + @numCalls
              @secretAccessKey = 'VALIDSECRET' + @numCalls
            cb()

        service.config.credentials = creds

        response = makeRequest(->)
        expect(response.retryCount).toEqual(1)
        expect(creds.accessKeyId).toEqual('VALIDKEY1')
        expect(creds.secretAccessKey).toEqual('VALIDSECRET1')

    [301, 307].forEach (code) ->
      it 'attempts to redirect on ' + code + ' responses', ->
        helpers.mockHttpResponse code, {location: 'http://redirected'}, ''
        service.config.maxRetries = 0
        service.config.maxRedirects = 5
        response = makeRequest(->)
        expect(response.request.httpRequest.endpoint.host).toEqual('redirected')
        expect(response.error.retryable).toEqual(true)
        expect(response.redirectCount).toEqual(service.config.maxRedirects)
        expect(delays).toEqual([0, 0, 0, 0, 0])

    it 'does not redirect if 3xx is missing location header', ->
      helpers.mockHttpResponse 304, {}, ''
      service.config.maxRetries = 0
      response = makeRequest(->)
      expect(response.request.httpRequest.endpoint.host).not.toEqual('redirected')
      expect(response.error.retryable).toEqual(false)

  describe 'success', ->
    it 'emits success on a successful response', ->
      # fail every request with a fake networking error
      helpers.mockHttpResponse 200, {}, 'Success!'

      response = makeRequest(->)

      expect(retryHandler).not.toHaveBeenCalled()
      expect(errorHandler).not.toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()
      expect(successHandler).toHaveBeenCalled()
      expect(response.retryCount).toEqual(0);

  describe 'error', ->
    it 'emits error if error found and should not be retrying', ->
      # fail every request with a fake networking error
      helpers.mockHttpResponse 400, {}, ''

      response = makeRequest(->)

      expect(retryHandler).toHaveBeenCalled()
      expect(errorHandler).toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()
      expect(successHandler).not.toHaveBeenCalled()
      expect(response.retryCount).toEqual(0)

    it 'emits error if an error is set in extractError', ->
      error = code: 'ParseError', message: 'error message'
      extractDataHandler = jasmine.createSpy('extractData')

      helpers.mockHttpResponse 400, {}, ''

      request = makeRequest()
      request.on('extractData', extractDataHandler)
      request.on('extractError', (resp) -> resp.error = error)
      response = request.send(->)

      expect(response.error).toBe(error)
      expect(extractDataHandler).not.toHaveBeenCalled()
      expect(retryHandler).toHaveBeenCalled()
      expect(errorHandler).toHaveBeenCalled()
      expect(completeHandler).toHaveBeenCalled()

  describe 'logging', ->
    data = null
    logger = null
    logfn = (d) -> data += d
    match = /\[AWS mock 200 .* 0 retries\] mockMethod\(.*foo.*bar.*\)/

    beforeEach ->
      data = ''
      logger = {}
      service = new MockService(logger: logger)

    it 'does nothing if logging is off', ->
      service = new MockService(logger: null)
      helpers.mockHttpResponse 200, {}, []
      makeRequest().send()
      expect(completeHandler).toHaveBeenCalled()

    it 'calls .log() on logger if it is available', ->
      helpers.mockHttpResponse 200, {}, []
      logger.log = logfn
      makeRequest().send()
      expect(data).toMatch(match)

    it 'calls .write() on logger if it is available', ->
      helpers.mockHttpResponse 200, {}, []
      logger.write = logfn
      makeRequest().send()
      expect(data).toMatch(match)

  describe 'terminal callback error handling', ->
    describe 'without domains', ->
      it 'emits uncaughtException', ->
        helpers.mockHttpResponse 200, {}, []
        expect(-> (makeRequest -> invalidCode)).toThrow()
        expect(completeHandler).toHaveBeenCalled()
        expect(errorHandler).not.toHaveBeenCalled()
        expect(retryHandler).not.toHaveBeenCalled()

      ['error', 'complete'].forEach (evt) ->
        it 'raise exceptions from terminal ' + evt + ' events', ->
          helpers.mockHttpResponse 500, {}, []
          request = makeRequest()
          expect(-> request.send(-> invalidCode)).toThrow()
          expect(completeHandler).toHaveBeenCalled()

    if AWS.util.isNode()
      describe 'with domains', ->
        it 'sends error raised from complete event to a domain', ->
          result = false
          d = require('domain').create()
          if d.run
            d.enter()
            d.on('error', (e) -> result = e)
            d.run ->
              helpers.mockHttpResponse 200, {}, []
              request = makeRequest()
              request.on 'complete', -> invalidCode
              expect(-> request.send()).not.toThrow()
              expect(completeHandler).toHaveBeenCalled()
              expect(retryHandler).not.toHaveBeenCalled()
              expect(result.name).toEqual('ReferenceError')
              d.exit()

        it 'does not leak service error into domain', ->
          result = false
          d = require('domain').create()
          if d.run
            d.on('error', (e) -> result = e)
            d.enter()
            d.run ->
              helpers.mockHttpResponse 500, {}, []
              makeRequest().send()
              expect(completeHandler).toHaveBeenCalled()
              expect(result).toEqual(false)
              d.exit()

        it 'supports inner domains', (done) ->
          helpers.mockHttpResponse 200, {}, []

          err = new ReferenceError()
          gotOuterError = false
          gotInnerError = false
          Domain = require("domain")
          outerDomain = Domain.create()
          outerDomain.on 'error', -> gotOuterError = true

          if outerDomain.run
            outerDomain.enter()
            outerDomain.run ->
              request = makeRequest()
              innerDomain = Domain.create()
              innerDomain.enter()
              innerDomain.add(request)
              innerDomain.on 'error', ->
                gotInnerError = true
                expect(gotOuterError).toEqual(false)
                expect(gotInnerError).toEqual(true)
                expect(err.domainThrown).toEqual(false)
                expect(err.domain).toBe(innerDomain)
                innerDomain.exit()
                outerDomain.exit()
                done()

              request.send ->
                  innerDomain.run -> throw err
