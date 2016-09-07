utils = require '../lib/utils'
errors = require '../commons/errors'
wrap = require 'co-express'
database = require '../commons/database'
parse = require '../commons/parse'
{ postPatch } = require './patchable'
mongoose = require 'mongoose'
Patch = require '../models/Patch'

module.exports.post = wrap (req, res) ->
  if not req.body.target?.collection
    throw new errors.UnprocessableEntity('target.collection not provided')
  collection = req.body.target?.collection
  Model = mongoose.model(req.body.target?.collection)
  if not Model
    throw new errors.NotFound('target.collection is not a known model')
  console.log 'model', Model.modelName
  if not Model.schema.is_patchable
    throw new errors.UnprocessableEntity('target.collection is not patchable')
  yield postPatch(Model, collection)(req, res)

module.exports.setStatus = wrap (req, res) ->
  newStatus = req.body.status or req.body
  unless newStatus in ['rejected', 'accepted', 'withdrawn']
    throw new errors.UnprocessableEntity('Status must be "rejected", "accepted", or "withdrawn"')

  patch = yield database.getDocFromHandle(req, Patch)
  if not patch
    throw new errors.NotFound('Could not find patch')
    
  Model = mongoose.model(patch.get('target.collection'))
  original = patch.get('target.original')
  query = { $or: [{original}, {'_id': mongoose.Types.ObjectId(original)}] }
  sort = { 'version.major': -1, 'version.minor': -1 }
  target = yield Model.findOne(query).sort(sort)
  if not target
    throw new errors.NotFound('Could not find patch')
    
  if newStatus in ['rejected', 'accepted']
    unless req.user.hasPermission('artisan') or target.hasPermissionsForMethod?(req.user, 'put')
      throw new errors.Forbidden('You do not have access to or own the target document.')

  if newStatus is 'withdrawn'
    unless req.user._id.equals patch.get('creator')
      throw new errors.Forbidden('Only the patch creator can withdraw their patch.')

  patch.set 'status', newStatus

  # Only increment statistics upon very first accept
  if patch.isNewlyAccepted()
    patch.set 'acceptor', req.user.get('id')
    acceptor = req.user.get 'id'
    submitter = patch.get 'creator'
    User.incrementStat acceptor, 'stats.patchesAccepted'
    # TODO maybe merge these increments together
    if patch.isTranslationPatch()
      User.incrementStat submitter, 'stats.totalTranslationPatches'
      User.incrementStat submitter, User.statsMapping.translations[targetModel.modelName]
    if patch.isMiscPatch()
      User.incrementStat submitter, 'stats.totalMiscPatches'
      User.incrementStat submitter, User.statsMapping.misc[targetModel.modelName]

  # these require callbacks
  yield patch.save()
  target.update {$pull:{patches:patch.get('_id')}}, {}, _.noop
  res.send(patch.toObject({req}))
