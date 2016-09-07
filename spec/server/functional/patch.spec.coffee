require '../common'
User = require '../../../server/models/User'
Article = require '../../../server/models/Article'
Patch = require '../../../server/models/Patch'
request = require '../request'
utils = require '../utils'

makeArticle = utils.wrap (done) ->
  creator = yield utils.initAdmin()
  yield utils.loginUser(creator)
  @article = yield utils.makeArticle()
  @json = {
    commitMessage: 'Accept this patch!'
    delta: { name: ['test'] }
    target:
      id: @article.id
      collection: 'article'
  }
  @url = utils.getURL('/db/patch')
  @user = yield utils.initUser()
  yield utils.loginUser(@user)
  done()

describe 'POST /db/patch', ->
  beforeEach makeArticle

  it 'allows someone to submit a patch to something they don\'t control', utils.wrap (done) ->
    [res, body] = yield request.postAsync { @url, @json }
    expect(res.statusCode).toBe(201)
    expect(body.target.original).toBe(@article.get('original').toString())
    expect(body.target.version.major).toBeDefined()
    expect(body.target.version.minor).toBeDefined()
    expect(body.status).toBe('pending')
    expect(body.created).toBeDefined()
    expect(body.creator).toBe(@user.id)
    done()

  it 'adds a patch to the target document', utils.wrap (done) ->
    [res, body] = yield request.postAsync { @url, @json }
    article = yield Article.findById(@article.id)
    expect(article.get('patches').length).toBe(1)
    done()

  it 'shows up in patch requests', utils.wrap (done) ->
    [res, body] = yield request.postAsync { @url, @json }
    patchID = res.body._id
    url = utils.getURL("/db/article/#{@article.id}/patches")
    [res, body] = yield request.getAsync { url, json: true }
    expect(res.statusCode).toBe(200)
    expect(body.length).toBe(1)
    expect(body[0]._id).toBe(patchID)
    done()


describe 'PUT /db/:collection/:handle/watch', ->
  beforeEach makeArticle
  
  it 'adds the user to the list of watchers idempotently when body is {on: true}', utils.wrap (done) ->
    url = getURL("/db/article/#{@article.id}/watch")
    [res, body] = yield request.putAsync({url, json: {on: true}})
    expect(body.watchers[1]).toBeDefined()
    expect(_.last(body.watchers)).toBe(@user.id)
    previousWatchers = body.watchers
    [res, body] = yield request.putAsync({url, json: {on: true}})
    expect(_.isEqual(previousWatchers, body.watchers)).toBe(true)
    done()

  it 'removes user from the list of watchers when body is {on: false}', utils.wrap (done) ->
    url = getURL("/db/article/#{@article.id}/watch")
    [res, body] = yield request.putAsync({url, json: {on: true}})
    expect(_.contains(body.watchers, @user.id)).toBe(true)
    [res, body] = yield request.putAsync({url, json: {on: false}})
    expect(_.contains(body.watchers, @user.id)).toBe(false)
    done()
    
    
describe 'PUT /db/patch/:handle/status', ->
  beforeEach makeArticle
  
  beforeEach utils.wrap (done) ->
    [res, body] = yield request.postAsync { url: utils.getURL('/db/patch'), @json }
    @patchID = body._id
    @url = utils.getURL("/db/patch/#{@patchID}/status")
    done()

  it 'withdraws the submitter\'s patch', utils.wrap (done) ->
    [res, body] = yield request.putAsync {@url, json: {status: 'withdrawn'}}
    expect(res.statusCode).toBe(200)
    expect(body.status).toBe('withdrawn')
    article = yield Article.findById(@article.id)
    expect(article.get('patches').length).toBe(0)
    done()

  it 'does not allow the submitter to reject or accept the pull request', utils.wrap (done) ->
    [res, body] = yield request.putAsync {@url, json: {status: 'rejected'}}
    expect(res.statusCode).toBe(403)
    [res, body] = yield request.putAsync {@url, json: {status: 'accepted'}}
    expect(res.statusCode).toBe(403)
    patch = yield Patch.findById(@patchID)
    expect(patch.get('status')).toBe('pending')
    done()

#  it 'allows the recipient to accept or reject the pull request', (done) ->
#    statusURL = getURL("/db/patch/#{patches[0]._id}/status")
#    loginAdmin ->
#      request.put {uri: statusURL, json: {status: 'rejected'}}, (err, res, body) ->
#        expect(res.statusCode).toBe(200)
#        Patch.findOne({}).exec (err, article) ->
#          expect(article.get('status')).toBe 'rejected'
#          request.put {uri: statusURL, json: {status: 'accepted'}}, (err, res, body) ->
#            expect(res.statusCode).toBe(200)
#            Patch.findOne({}).exec (err, article) ->
#              expect(article.get('status')).toBe 'accepted'
#              expect(article.get('acceptor')).toBeDefined()
#              done()
#
#  it 'keeps track of amount of submitted and accepted patches', (done) ->
#    loginJoe (joe) ->
#      User.findById joe.get('_id'), (err, guy) ->
#        expect(err).toBeNull()
#        expect(guy.get 'stats.patchesSubmitted').toBe 1
#        expect(guy.get 'stats.patchesContributed').toBe 1
#        expect(guy.get 'stats.totalMiscPatches').toBe 1
#        expect(guy.get 'stats.articleMiscPatches').toBe 1
#        expect(guy.get 'stats.totalTranslationPatches').toBeUndefined()
#        done()
#
#  it 'recalculates amount of submitted and accepted patches', (done) ->
#    loginJoe (joe) ->
#      User.findById joe.get('_id'), (err, joe) ->
#        expect(joe.get 'stats.patchesSubmitted').toBe 1
#        joe.update {$unset: stats: ''}, (err) ->
#          UserHandler.modelClass.findById joe.get('_id'), (err, joe) ->
#            expect(err).toBeNull()
#            expect(joe.get 'stats').toBeUndefined()
#            async.parallel [
#              (done) -> UserHandler.recalculateStats 'patchesContributed', done
#              (done) -> UserHandler.recalculateStats 'patchesSubmitted', done
#              (done) -> UserHandler.recalculateStats 'totalMiscPatches', done
#              (done) -> UserHandler.recalculateStats 'totalTranslationPatches', done
#              (done) -> UserHandler.recalculateStats 'articleMiscPatches', done
#            ], (err) ->
#              expect(err).toBeNull()
#              UserHandler.modelClass.findById joe.get('_id'), (err, joe) ->
#                expect(joe.get 'stats.patchesSubmitted').toBe 1
#                expect(joe.get 'stats.patchesContributed').toBe 1
#                expect(joe.get 'stats.totalMiscPatches').toBe 1
#                expect(joe.get 'stats.articleMiscPatches').toBe 1
#                expect(joe.get 'stats.totalTranslationPatches').toBeUndefined()
#                done()
#
#  it 'does not allow the recipient to withdraw the pull request', (done) ->
#    loginAdmin ->
#      statusURL = getURL("/db/patch/#{patches[0]._id}/status")
#      request.put {uri: statusURL, json: {status:'withdrawn'}}, (err, res, body) ->
#        expect(res.statusCode).toBe(403)
#        Patch.findOne({}).exec (err, article) ->
#          expect(article.get('status')).toBe 'accepted'
#          done()
#
#  it 'only allows artisans and admins to set patch status for courses', utils.wrap (done) ->
#    submitter = yield utils.initUser()
#    course = yield utils.makeCourse()
#    patch = new Patch({
#      delta: { name: 'test' }
#      target: { collection: 'course', id: course._id, original: course._id }
#      creator: submitter._id
#      status: 'pending'
#      commitMessage: '...'
#    })
#    yield patch.save()
#    anotherUser = yield utils.initUser()
#    yield utils.loginUser(anotherUser)
#    json = { status: 'rejected' }
#    [res, body] = yield request.putAsync({ url: utils.getURL("/db/patch/#{patch.id}/status"), json})
#    expect(res.statusCode).toBe(403)
#    done()
