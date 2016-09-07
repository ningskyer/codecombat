utils = require '../lib/utils'
errors = require '../commons/errors'
wrap = require 'co-express'
Promise = require 'bluebird'
Patch = require '../models/Patch'
mongoose = require 'mongoose'
database = require '../commons/database'
parse = require '../commons/parse'
slack = require '../slack'
{ isJustFillingTranslations } = require '../commons/deltas'
{ updateI18NCoverage } = require '../commons/i18n'

module.exports =
  patches: (Model, options={}) -> wrap (req, res) ->
    dbq = Patch.find()
    dbq.limit(parse.getLimitFromReq(req))
    dbq.skip(parse.getSkipFromReq(req))
    dbq.select(parse.getProjectFromReq(req))

    doc = yield database.getDocFromHandle(req, Model, {_id: 1})
    if not doc
      throw new errors.NotFound('Patchable document not found')
      
    query =
      $or: [
        {'target.original': doc.id }
        {'target.original': doc._id }
      ]
    if req.query.status
      query.status = req.query.status
    if req.user and req.query.creator is req.user.id
      query.creator = req.user._id
    
    patches = yield dbq.find(query).sort('-created')
    res.status(200).send(patches)

  joinWatchers: (Model, options={}) -> wrap (req, res) ->
    doc = yield database.getDocFromHandle(req, Model)
    if not doc
      throw new errors.NotFound('Document not found.')
    if not database.hasAccessToDocument(req, doc, 'get')
      throw new errors.Forbidden()
    updateResult = yield doc.update({ $addToSet: { watchers: req.user.get('_id') }})
    if updateResult.nModified
      watchers = doc.get('watchers')
      watchers.push(req.user.get('_id'))
      doc.set('watchers', watchers)
    res.status(200).send(doc)
    
  leaveWatchers: (Model, options={}) -> wrap (req, res) ->
    doc = yield database.getDocFromHandle(req, Model)
    if not doc
      throw new errors.NotFound('Document not found.')
    updateResult = yield doc.update({ $pull: { watchers: req.user.get('_id') }})
    if updateResult.nModified
      watchers = doc.get('watchers')
      watchers = _.filter watchers, (id) -> not id.equals(req.user._id)
      doc.set('watchers', watchers)
    res.status(200).send(doc)

  postPatch: (Model, collectionName, options={}) -> wrap (req, res) ->
    if req.body.target?.id
      target = yield Model.findById(req.body.target.id)
    else
      target = yield database.getDocFromHandle(req, Model)
    if not target
      throw new errors.NotFound('Target not found.')

    originalDelta = req.body.delta
    originalTarget = target.toObject()
    changedTarget = _.cloneDeep(target.toObject(), (value) ->
      return value if value instanceof mongoose.Types.ObjectId
      return value if value instanceof Date
      return undefined
    )
    jsondiffpatch.patch(changedTarget, originalDelta)

    # normalize the delta because in tests, changes to patches would sneak in and cause false positives
    # TODO: Figure out a better system. Perhaps submit a series of paths? I18N Edit Views already use them for their rows.
    normalizedDelta = jsondiffpatch.diff(originalTarget, changedTarget)
    normalizedDelta = _.pick(normalizedDelta, _.keys(originalDelta))
    reasonNotAutoAccepted = undefined

    validation = tv4.validateMultiple(changedTarget, Model.jsonSchema)
    if not validation.valid
      reasonNotAutoAccepted = 'Did not pass json schema.'
    else if not isJustFillingTranslations(normalizedDelta)
      reasonNotAutoAccepted = 'Adding to existing translations.'
    else
      target.set(changedTarget)
      updateI18NCoverage(target)
      yield target.save()

    if Model.schema.uses_coco_versions
      patchTarget = {
        collection: collectionName
        id: target._id
        original: target._id
        version: _.pick(target.get('version'), 'major', 'minor')
      }
    else
      patchTarget = {
        collection: collectionName
        id: target._id
        original: target._id
      }

    patch = new Patch()
    patch.set({
      delta: normalizedDelta
      commitMessage: req.body.commitMessage
      target: patchTarget
      creator: req.user._id
      status: if reasonNotAutoAccepted then 'pending' else 'accepted'
      created: new Date().toISOString()
      reasonNotAutoAccepted: reasonNotAutoAccepted
    })
    database.validateDoc(patch)

    if reasonNotAutoAccepted
      yield target.update({ $addToSet: { patches: patch._id }})
      patches = target.get('patches') or []
      patches.push patch._id
      target.set({patches})
    yield patch.save()

    res.status(201).send(patch.toObject({req: req}))

    docLink = "https://codecombat.com/editor/#{collectionName}/#{target.id}"
    message = "#{req.user.get('name')} submitted a patch to #{target.get('name')}: #{patch.get('commitMessage')} #{docLink}"
    slack.sendSlackMessage message, ['artisans']
