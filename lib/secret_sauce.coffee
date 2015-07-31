os    = require("os")
chalk = require("chalk")

SecretSauce =
  mixin: (module, klass) ->
    for key, fn of @[module]
      klass.prototype[key] = fn

SecretSauce.Cli = (App, options) ->
  write = (str) ->
    process.stdout.write(str + "\n")

  writeErr = (str, msgs...) ->
    str = [chalk.red(str)].concat(msgs).join(" ")
    write(str)
    process.exit(1)

  displayToken = (token) ->
    write(token)
    process.exit()

  displayTokenError = ->
    writeErr("An error occured receiving token.")

  ensureLinuxEnv = ->
    return true if os.platform() is "linx64"

    writeErr("Sorry, cannot run in CI mode. You must be on a linux operating system.")

  ensureSessionToken = (user) ->
    ## bail if we have a session_token
    return true if user.get("session_token")

    ## else die and log out the auth error
    writeErr("Sorry, you are not currently logged into Cypress. This request requires authentication.\nPlease log into Cypress and then issue this command again.")

  class Cli
    constructor: (@App, options = {}) ->
      @user = @App.currentUser

      @parseCliOptions(options)

    parseCliOptions: (options) ->
      switch
        when options.ci           then @ci(options)
        when options.getKey       then @getKey()
        when options.generateKey  then @generateKey()
        # when options.openProject  then @openProject(user, options)
        when options.runProject   then @runProject(options)
        else
          @startGuiApp(options)

    getKey: ->
      if ensureSessionToken(@user)

        ## log out the API Token
        @App.config.getToken(@user)
          .then(displayToken)
          .catch(displayTokenError)

    generateKey: ->
      if ensureSessionToken(@user)

        ## generate a new API Token
        @App.config.generateToken(@user)
          .then(displayToken)
          .catch(displayTokenError)

    runProject: (options) ->
      if ensureSessionToken(@user)

        ## silence all console messages
        @App.silenceConsole()

        @App.vent.trigger "start:projects:app", {
          spec:        options.spec
          reporter:    options.reporter
          projectPath: options.projectPath
          onProjectNotFound: (path) ->
            writeErr("Cannot run project because it was not found:", chalk.blue(path))
        }

    ci: (options) ->
      if ensureSessionToken(@user)
        if ensureLinuxEnv()
          "asfd"

      ## bail if we arent in a recognized CI environment
      ## add project first
      ## then runProject
      ## XVFB?
      ## attempt to run in XVFB and die if we cant?
      ## just say we only support linux based CI providers ATM
      ## store the machine guid and store it in cypress servers?
      ## CI must have internet access

    startGuiApp: (options) ->
      if options.session
        ## if have it, start projects
        @App.vent.trigger "start:projects:app"
      else
        ## else login
        @App.vent.trigger "start:login:app"

      ## display the footer
      @App.vent.trigger "start:footer:app"

      ## display the GUI
      @App.execute "gui:display", options.coords

  new Cli(App, options)

## change this to be a function like CLI
SecretSauce.Chromium =
  override: (options = {}) ->
    { _ } = SecretSauce

    @window.require = require

    _.defaults options,
      headless: false

    return if options.headless is false

    _.extend @window.Mocha.process, process

    @_reporter(@window)
    @_onerror(@window)
    @_log(@window)
    @_afterRun(@window)

  _reporter: (window) ->
    window.$Cypress.reporter = require("mocha/lib/reporters/spec")

  _onerror: (window) ->
    # window.onerror = (err) ->
      # ## log out the error to stdout

      # ## notify Cypress API

      # process.exit(1)

  _log: (window) ->
    util = @util

    window.console.log = ->
      msg = util.format.apply(util, arguments)
      process.stdout.write(msg + "\n")

  _afterRun: (window) ->
    window.$Cypress.afterRun = (results) ->
      process.stdout.write("Results are:\n")
      process.stdout.write JSON.stringify(results)
      process.stdout.write("\n")
      # console.log("results", results)
      ## notify Cypress API

      process.exit()

SecretSauce.Keys =
  _convertToId: (index) ->
    ival = index.toString(36)
    ## 0 pad number to ensure three digits
    [0,0,0].slice(ival.length).join("") + ival

  _getProjectKeyRange: (id) ->
    @cache.getProject(id).get("RANGE")

  ## Lookup the next Test integer and update
  ## offline location of sync
  getNextTestNumber: (projectId) ->
    @_getProjectKeyRange(projectId)
    .then (range) =>
      return @_getNewKeyRange(projectId) if range.start is range.end

      range.start += 1
      range
    .then (range) =>
      range = JSON.parse(range) if SecretSauce._.isString(range)
      @Log.info "Received key range", {range: range}
      @cache.updateRange(projectId, range)
      .return(range.start)

  nextKey: ->
    @project.ensureProjectId().bind(@)
    .then (projectId) ->
      @cache.ensureProject(projectId).bind(@)
      .then -> @getNextTestNumber(projectId)
      .then @_convertToId

SecretSauce.Socket =
  leadingSlashes: /^\/+/

  onTestFileChange: (filePath, stats) ->
    @Log.info "onTestFileChange", filePath: filePath

    ## simple solution for preventing firing test:changed events
    ## when we are making modifications to our own files
    return if @app.enabled("editFileMode")

    ## return if we're not a js or coffee file.
    ## this will weed out directories as well
    return if not /\.(js|coffee)$/.test filePath

    @fs.statAsync(filePath).bind(@)
      .then ->
        ## strip out our testFolder path from the filePath, and any leading forward slashes
        filePath      = filePath.split(@app.get("cypress").projectRoot).join("").replace(@leadingSlashes, "")
        strippedPath  = filePath.replace(@app.get("cypress").testFolder, "").replace(@leadingSlashes, "")

        @Log.info "generate:ids:for:test", filePath: filePath, strippedPath: strippedPath
        @io.emit "generate:ids:for:test", filePath, strippedPath
      .catch(->)

  closeWatchers: ->
    if f = @watchedTestFile
      f.close()

  watchTestFileByPath: (testFilePath) ->
    ## normalize the testFilePath
    testFilePath = @path.join(@testsDir, testFilePath)

    ## bail if we're already watching this
    ## exact file
    return if testFilePath is @testFilePath

    @Log.info "watching test file", {path: testFilePath}

    ## store this location
    @testFilePath = testFilePath

    ## close existing watchedTestFile(s)
    ## since we're now watching a different path
    @closeWatchers()

    new @Promise (resolve, reject) =>
      @watchedTestFile = @chokidar.watch testFilePath
      @watchedTestFile.on "change", @onTestFileChange.bind(@)
      @watchedTestFile.on "ready", =>
        resolve @watchedTestFile
      @watchedTestFile.on "error", (err) =>
        @Log.info "watching test file failed", {error: err, path: testFilePath}
        reject err

  onFixture: (fixture, cb) ->
    @Fixtures(@app).get(fixture)
      .then(cb)
      .catch (err) ->
        cb({__error: err.message})

  _runSauce: (socket, spec, fn) ->
    { _ } = SecretSauce

    ## this will be used to group jobs
    ## together for the runs related to 1
    ## spec by setting custom-data on the job object
    batchId = Date.now()

    jobName = @app.get("cypress").testFolder + "/" + spec
    fn(jobName, batchId)

    ## need to handle platform/browser/version incompatible configurations
    ## and throw our own error
    ## https://saucelabs.com/platforms/webdriver
    jobs = [
      { platform: "Windows 8.1", browser: "chrome",  version: 43, resolution: "1280x1024" }
      { platform: "Windows 8.1", browser: "internet explorer",  version: 11, resolution: "1280x1024" }
      # { platform: "Windows 7",   browser: "internet explorer",  version: 10 }
      # { platform: "Linux",       browser: "chrome",             version: 37 }
      { platform: "Linux",       browser: "firefox",            version: 33  }
      { platform: "OS X 10.9",   browser: "safari",             version: 7 }
    ]

    normalizeJobObject = (obj) ->
      obj = _.clone obj

      obj.browser = {
        "internet explorer": "ie"
      }[obj.browserName] or obj.browserName

      obj.os = obj.platform

      return _.pick obj, "manualUrl", "browser", "version", "os", "batchId", "guid"

    _.each jobs, (job) =>
      url = @app.get("cypress").clientUrl + "#/" + jobName
      options =
        manualUrl:        url
        remoteUrl:        url + "?nav=false"
        batchId:          batchId
        guid:             @uuid.v4()
        browserName:      job.browser
        version:          job.version
        platform:         job.platform
        screenResolution: job.resolution ? "1024x768"
        onStart: (sessionID) ->
          ## pass up the sessionID to the previous client obj by its guid
          socket.emit "sauce:job:start", clientObj.guid, sessionID

      clientObj = normalizeJobObject(options)
      socket.emit "sauce:job:create", clientObj

      @sauce(options)
        .then (obj) ->
          {sessionID, runningTime, passed} = obj
          socket.emit "sauce:job:done", sessionID, runningTime, passed
        .catch (err) ->
          socket.emit "sauce:job:fail", clientObj.guid, err

  _startListening: (chokidar, path, options) ->
    { _ } = SecretSauce

    _.defaults options,
      onChromiumRun: ->

    messages = {}

    {projectRoot, testFolder} = @app.get("cypress")

    @io.on "connection", (socket) =>
      @Log.info "socket connected"

      socket.on "remote:connected", =>
        @Log.info "remote:connected"

        return if socket.inRemoteRoom

        socket.inRemoteRoom = true
        socket.join("remote")

        socket.on "remote:response", (id, response) =>
          if message = messages[id]
            delete messages[id]
            @Log.info "remote:response", id: id, response: response
            message(response)

      socket.on "client:request", (message, data, cb) =>
        ## if cb isnt a function then we know
        ## data is really the cb, so reassign it
        ## and set data to null
        if not _.isFunction(cb)
          cb = data
          data = null

        id = @uuid.v4()

        @Log.info "client:request", id: id, msg: message, data: data

        if _.keys(@io.sockets.adapter.rooms.remote).length > 0
          messages[id] = cb
          @io.to("remote").emit "remote:request", id, message, data
        else
          cb({__error: "Could not process '#{message}'. No remote servers connected."})

      socket.on "run:tests:in:chromium", (src) ->
        options.onChromiumRun(src)

      socket.on "watch:test:file", (filePath) =>
        @watchTestFileByPath(filePath)

      socket.on "generate:test:id", (data, fn) =>
        @Log.info "generate:test:id", data: data

        @idGenerator.getId(data)
        .then(fn)
        .catch (err) ->
          console.log "\u0007", err.details, err.message
          fn(message: err.message)

      socket.on "fixture", =>
        @onFixture.apply(@, arguments)

      socket.on "finished:generating:ids:for:test", (strippedPath) =>
        @Log.info "finished:generating:ids:for:test", strippedPath: strippedPath
        @io.emit "test:changed", file: strippedPath

      _.each "load:spec:iframe url:changed page:loading command:add command:attrs:changed runner:start runner:end before:run before:add after:add suite:add suite:start suite:stop test test:add test:start test:end after:run test:results:ready exclusive:test".split(" "), (event) =>
        socket.on event, (args...) =>
          args = _.chain(args).reject(_.isUndefined).reject(_.isFunction).value()
          @io.emit event, args...

      ## when we're told to run:sauce we receive
      ## the spec and callback with the name of our
      ## sauce labs job
      ## we'll embed some additional meta data into
      ## the job name
      socket.on "run:sauce", (spec, fn) =>
        @_runSauce(socket, spec, fn)

    @testsDir = path.join(projectRoot, testFolder)

    @fs.ensureDirAsync(@testsDir).bind(@)

    ## BREAKING DUE TO __DIRNAME
    # watchCssFiles = chokidar.watch path.join(__dirname, "public", "css"), ignored: (path, stats) ->
    #   return false if fs.statSync(path).isDirectory()

    #   not /\.css$/.test path

    # # watchCssFiles.on "add", (path) -> console.log "added css:", path
    # watchCssFiles.on "change", (filePath, stats) =>
    #   filePath = path.basename(filePath)
    #   @io.emit "eclectus:css:changed", file: filePath

SecretSauce.IdGenerator =
  hasExistingId: (e) ->
    e.idFound

  idFound: ->
    e = new Error
    e.idFound = true
    throw e

  nextId: (data) ->
    @keys.nextKey().bind(@)
    .then((id) ->
      @Log.info "Appending ID to Spec", {id: id, spec: data.spec, title: data.title}
      @appendTestId(data.spec, data.title, id)
      .return(id)
    )
    .catch (e) ->
      @logErr(e, data.spec)

      throw e

  appendTestId: (spec, title, id) ->
    normalizedPath = @path.join(@projectRoot, spec)

    @read(normalizedPath).bind(@)
    .then (contents) ->
      @insertId(contents, title, id)
    .then (contents) ->
      ## enable editFileMode which prevents us from sending out test:changed events
      @editFileMode(true)

      ## write the new content back to the file
      @write(normalizedPath, contents)
    .then ->
      ## remove the editFileMode so we emit file changes again
      ## if we're still in edit file mode then wait 1 second and disable it
      ## chokidar doesnt instantly see file changes so we have to wait
      @editFileMode(false, {delay: 1000})
    .catch @hasExistingId, (err) ->
      ## do nothing when the ID is existing

  insertId: (contents, title, id) ->
    re = new RegExp "['\"](" + @escapeRegExp(title) + ")['\"]"

    # ## if the string is found and it doesnt have an id
    matches = re.exec contents

    ## matches[1] will be the captured group which is the title
    return @idFound() if not matches

    ## position is the string index where we first find the capture
    ## group and include its length, so we insert right after it
    position = matches.index + matches[1].length + 1
    @str.insert contents, position, " [#{id}]"

SecretSauce.RemoteInitial =
  okStatus: /^[2|3|4]\d+$/
  badCookieParam: /^(httponly|secure)$/i

  _handle: (req, res, next, Domain) ->
    { _ } = SecretSauce

    d = Domain.create()

    d.on 'error', (e) => @errorHandler(e, req, res)

    d.run =>
      ## 1. first check to see if this url contains a FQDN
      ## if it does then its been rewritten from an absolute-domain
      ## into a absolute-path-relative link, and we should extract the
      ## remoteHost from this URL
      ## 2. or use cookies
      ## 3. or use baseUrl
      ## 4. or finally fall back on app instance var
      remoteHost = @getOriginFromFqdnUrl(req) ? req.cookies["__cypress.remoteHost"] ? @app.get("cypress").baseUrl ? @app.get("__cypress.remoteHost")

      @Log.info "handling initial request", url: req.url, remoteHost: remoteHost

      ## we must have the remoteHost which tell us where
      ## we should request the initial HTML payload from
      if not remoteHost
        throw new Error("Missing remoteHost. Cannot proxy request: #{req.url}")

      thr = @through (d) -> @queue(d)

      @getContent(thr, req, res, remoteHost)
        .on "error", (e) => @errorHandler(e, req, res, remoteHost)
        .pipe(res)

  getOriginFromFqdnUrl: (req) ->
    ## if we find an origin from this req.url
    ## then return it, and reset our req.url
    ## after stripping out the origin and ensuring
    ## our req.url starts with only 1 leading slash
    if origin = @UrlHelpers.getOriginFromFqdnUrl(req.url)
      req.url = "/" + req.url.replace(origin, "").replace(/^\/+/, "")

      ## return the origin
      return origin

  getContent: (thr, req, res, remoteHost) ->
    switch remoteHost
      ## serve from the file system because
      ## we are using cypress as our weberver
      when "<root>"
        @getFileContent(thr, req, res, remoteHost)

      ## else go make an HTTP request to the
      ## real server!
      else
        @getHttpContent(thr, req, res, remoteHost)

  getHttpContent: (thr, req, res, remoteHost) ->
    { _ } = SecretSauce

    process.env.NODE_TLS_REJECT_UNAUTHORIZED = "0"

    ## prepends req.url with remoteHost
    remoteUrl = @url.resolve(remoteHost, req.url)

    setCookies = (initial, remoteHost) =>
      ## dont set the cookies if we're not on the initial request
      return if req.cookies["__cypress.initial"] isnt "true"

      res.cookie("__cypress.initial", initial)
      res.cookie("__cypress.remoteHost", remoteHost)
      @app.set("__cypress.remoteHost", remoteHost)

    ## we are setting gzip to false here to prevent automatic
    ## decompression of the response since we dont need to transform
    ## it and we can just hand it back to the client. DO NOT BE CONFUSED
    ## our request will still have 'accept-encoding' and therefore
    ## responses WILL be gzipped! Responses will simply not be unzipped!
    opts = {url: remoteUrl, gzip: false, followRedirect: false, strictSSL: false}

    ## do not accept gzip if this is initial
    ## since we have to rewrite html and we dont
    ## want to go through unzipping it, but we may
    ## do this later
    if req.cookies["__cypress.initial"] is "true"
      delete req.headers["accept-encoding"]

    ## rewrite problematic custom headers referencing
    ## the wrong host
    ## we need to use our cookie's remoteHost here and not necessarilly
    ## the remoteUrl
    ## this fixes a bug where we accidentally swapped out referer with the domain of the new url
    ## when it needs to stay as the previous referring remoteHost (from our cookie)
    ## also the host header NEVER includes the protocol so we need to add it here
    req.headers = @mapHeaders(req.headers, req.protocol + "://" + req.get("host"), req.cookies["__cypress.remoteHost"])

    rq = @request(opts)

    rq.on "error", (err) ->
      thr.emit("error", err)

    rq.on "response", (incomingRes) =>
      @setResHeaders(req, res, incomingRes, remoteHost)

      ## always proxy the cookies coming from the incomingRes
      if cookies = incomingRes.headers["set-cookie"]
        res.append("Set-Cookie", @stripCookieParams(cookies))

      if /^30(1|2|3|7|8)$/.test(incomingRes.statusCode)
        ## redirection is extremely complicated and there are several use-cases
        ## we are encompassing. read the routes_spec for each situation and
        ## why we have to check on so many things.

        ## we go through this merge because the spec states that the location
        ## header may not be a FQDN. If it's not (sometimes its just a /) then
        ## we need to merge in the missing url parts
        newUrl = new @jsUri @UrlHelpers.mergeOrigin(remoteUrl, incomingRes.headers.location)

        ## set cookies to initial=true and our new remoteHost origin
        setCookies(true, newUrl.origin())

        @Log.info "redirecting to new url", status: incomingRes.statusCode, url: newUrl.toString()

        isInitial = req.cookies["__cypress.initial"] is "true"

        ## finally redirect our user agent back to our domain
        ## by making this an absolute-path-relative redirect
        res.redirect @getUrlForRedirect(newUrl, req.cookies["__cypress.remoteHost"], isInitial)
      else
        ## set the status to whatever the incomingRes statusCode is
        res.status(incomingRes.statusCode)

        if not @okStatus.test incomingRes.statusCode
          return @errorHandler(null, req, res, remoteHost)

        @Log.info "received absolute file content"
        # if ct = incomingRes.headers["content-type"]
          # res.contentType(ct)
          # throw new Error("Missing header: 'content-type'")
        # res.contentType(incomingRes.headers['content-type'])

        ## turn off __cypress.initial by setting false here
        setCookies(false, remoteHost)

        if req.cookies["__cypress.initial"] is "true"
          # @rewrite(req, res, remoteHost)
          # res.isHtml = true
          rq.pipe(@rewrite(req, res, remoteHost)).pipe(thr)
        else
          rq.pipe(thr)

    ## proxy the request body, content-type, headers
    ## to the new rq
    req.pipe(rq)

    return thr

  getFileContent: (thr, req, res, remoteHost) ->
    { _ } = SecretSauce

    args = _.compact([
      @app.get("cypress").projectRoot,
      @app.get("cypress").rootFolder,
      req.url
    ])

    ## strip off any query params from our req's url
    ## since we're pulling this from the file system
    ## it does not understand query params
    file = @url.parse(@path.join(args...)).pathname

    req.formattedUrl = file

    @Log.info "getting relative file content", file: file

    ## set the content-type based on the file extension
    res.contentType(@mime.lookup(file))

    res.cookie("__cypress.initial", false)
    res.cookie("__cypress.remoteHost", remoteHost)
    @app.set("__cypress.remoteHost", remoteHost)

    stream = @fs.createReadStream(file, "utf8")

    if req.cookies["__cypress.initial"] is "true"
      stream.pipe(@rewrite(req, res, remoteHost)).pipe(thr)
    else
      stream.pipe(thr)

    return thr

  errorHandler: (e, req, res, remoteHost) ->
    remoteHost ?= req.cookies["__cypress.remoteHost"]

    url = @url.resolve(remoteHost, req.url)

    ## disregard ENOENT errors (that means the file wasnt found)
    ## which is a perfectly acceptable error (we account for that)
    if process.env["NODE_ENV"] isnt "production" and e and e.code isnt "ENOENT"
      console.error(e.stack)
      debugger

    @Log.info "error handling initial request", url: url, error: e

    filePath = switch
      when f = req.formattedUrl
        "file://#{f}"
      else
        url

    ## using req here to give us an opportunity to
    ## write to req.formattedUrl
    htmlPath = @path.join(process.cwd(), "lib/html/initial_500.html")
    res.status(500).render(htmlPath, {
      url: filePath
      fromFile: !!req.formattedUrl
    })

  mapHeaders: (headers, currentHost, remoteHost) ->
    { _ } = SecretSauce

    ## change out custom X-* headers referencing
    ## the wrong host
    hostRe = new RegExp(@escapeRegExp(currentHost), "ig")

    _.mapValues headers, (value, key) ->
      ## if we have a custom header then swap
      ## out any values referencing our currentHost
      ## with the remoteHost
      key = key.toLowerCase()
      if key is "referer" or key is "origin" or key.startsWith("x-")
        value.replace(hostRe, remoteHost)
      else
        ## just return the value
        value

  setResHeaders: (req, res, incomingRes, remoteHost) ->
    { _ } = SecretSauce

    ## omit problematic headers
    headers = _.omit incomingRes.headers, "set-cookie", "x-frame-options", "content-length"

    ## rewrite custom headers which reference the wrong host
    ## if our host is localhost:8080 we need to
    ## rewrite back to our current host localhost:2020
    headers = @mapHeaders(headers, remoteHost, req.get("host"))

    ## proxy the headers
    res.set(headers)

  getUrlForRedirect: (newUrl, remoteHostCookie, isInitial) ->
    ## if isInitial is true, then we're requesting initial content
    ## and we dont care if newUrl and remoteHostCookie matches because
    ## we've already rewritten the remoteHostCookie above
    ##
    ## if the origin of our newUrl matches the current remoteHostCookie
    ## then we're redirecting back to ourselves and we can make
    ## this an absolute-path-relative url to ourselves
    if isInitial or (newUrl.origin() is remoteHostCookie)
      newUrl.toString().replace(newUrl.origin(), "")
    else
      ## if we're not requesting initial content or these
      ## dont match then just prepend with a leading slash
      ## so we retain the remoteHostCookie in the newUrl (like how
      ## our original request came in!)
      "/" + newUrl.toString()

  stripCookieParams: (cookies) ->
    { _ } = SecretSauce

    stripHttpOnlyAndSecure = (cookie) =>
      ## trim out whitespace
      parts = _.invoke cookie.split(";"), "trim"

      ## reject any part that is httponly or secure
      parts = _.reject parts, (part) =>
        @badCookieParam.test(part)

      ## join back up with proper whitespace
      parts.join("; ")

    ## normalize cookies into single dimensional array
     _.map [].concat(cookies), stripHttpOnlyAndSecure

  rewrite: (req, res, remoteHost) ->
    { _ } = SecretSauce

    through = @through

    tr = @trumpet()

       # tr.selectAll selector, (elem) ->
        # elem.getAttribute attr, (val) ->
        #   elem.setAttribute attr, fn(val)

    rewrite = (selector, type, attr, fn) ->
      if _.isFunction(attr)
        fn   = attr
        attr = null

      tr.selectAll selector, (elem) ->
        switch type
          when "attr"
            elem.getAttribute attr, (val) ->
              elem.setAttribute attr, fn(val)

          when "removeAttr"
            elem.removeAttribute(attr)

          when "html"
            stream = elem.createStream({outer: true})
            stream.pipe(through (buf) ->
              @queue fn(buf.toString())
            ).pipe(stream)

    rewrite "head", "html", (str) =>
      str.replace("<head>", "<head> #{@getHeadContent()}")

    rewrite "[href^='//']", "attr", "href", (href) ->
      "/" + req.protocol + ":" + href

    rewrite "form[action^='//']", "attr", "action", (action) ->
      "/" + req.protocol + ":" + action

    rewrite "form[action^='http']", "attr", "action", (action) ->
      if action.startsWith(remoteHost)
        action.replace(remoteHost, "")
      else
        "/" + action

    rewrite "[href^='http']", "attr", "href", (href) ->
      if href.startsWith(remoteHost)
        href.replace(remoteHost, "")
      else
        "/" + href

    return tr

  getHeadContent: ->
    "
      <script type='text/javascript'>
        window.onerror = function(){
          parent.onerror.apply(parent, arguments);
        }
      </script>
      <script type='text/javascript' src='/__cypress/static/js/sinon.js'></script>
      <script type='text/javascript'>
        var Cypress = parent.Cypress;
        if (!Cypress){
          throw new Error('Cypress must exist in the parent window!');
        };
        Cypress.onBeforeLoad(window);
      </script>
    "

if module?
  module.exports = SecretSauce
else
  SecretSauce
