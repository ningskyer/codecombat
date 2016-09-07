RootView = require 'views/core/RootView'
locale = require 'locale/locale'
Patch = require 'models/Patch'
Patches = require 'collections/Patches'
PatchModal = require 'views/editor/PatchModal'
template = require 'templates/i18n/i18n-edit-model-view'
deltasLib = require 'core/deltas'

# in the template, but need to require to load them
require 'views/modal/RevertModal'

module.exports = class I18NEditModelView extends RootView
  className: 'editor i18n-edit-model-view'
  template: template

  events:
    'change .translation-input': 'onInputChanged'
    'change #language-select': 'onLanguageSelectChanged'
    'click #patch-submit': 'onSubmitPatch'
    'click .open-patch-link': 'onClickOpenPatchLink'

  constructor: (options, @modelHandle) ->
    super(options)

    @model = new @modelClass(_id: @modelHandle)
    @supermodel.trackRequest(@model.fetch())
    @patches = new Patches()
    @patches.comparator = '_id'
    @supermodel.trackRequest(@patches.fetchMineFor(@model))

    @selectedLanguage = me.get('preferredLanguage', true)
    @madeChanges = false

  showLoading: ($el) ->
    $el ?= @$el.find('.outer-content')
    super($el)

  onLoaded: ->
    super()
    @originalModel = @model.clone()

  getRenderData: ->
    c = super()

    c.model = @model
    c.selectedLanguage = @selectedLanguage

    @translationList = []
    if @supermodel.finished() then @buildTranslationList() else []
    result.index = index for result, index in @translationList
    c.translationList = @translationList

    c

  afterRender: ->
    super()

    @hush = true
    $select = @$el.find('#language-select').empty()
    @addLanguagesToSelect($select, @selectedLanguage)
    @$el.find('option[value="en-US"]').remove()
    @hush = false
    editors = []

    @$el.find('tr[data-format="markdown"]').each((index, el) =>
      foundEnEl = enEl=$(el).find('.english-value-row div')[0]
      if foundEnEl?
        englishEditor = ace.edit(foundEnEl)
        englishEditor.el = enEl
        englishEditor.setReadOnly(true)
        editors.push englishEditor
      foundToEl = toEl=$(el).find('.to-value-row div')[0]
      if foundToEl?
        toEditor = ace.edit(foundToEl)
        toEditor.el = toEl
        toEditor.on 'change', @onEditorChange
        editors.push toEditor
    )

    for editor in editors
      session = editor.getSession()
      session.setTabSize 2
      session.setMode 'ace/mode/markdown'
      session.setNewLineMode = 'unix'
      session.setUseSoftTabs true
      editor.setOptions({ maxLines: Infinity })

  onEditorChange: (event, editor) =>
    return if @destroyed
    index = $(editor.el).data('index')
    rowInfo = @translationList[index]
    value = editor.getValue()
    @onTranslationChanged(rowInfo, value)

  wrapRow: (title, key, enValue, toValue, path, format) ->
    @translationList.push {
      title: title,
      key: key,
      enValue: enValue,
      toValue: toValue or '',
      path: path
      format: format
    }

  buildTranslationList: -> [] # overwrite

  onInputChanged: (e) ->
    index = $(e.target).data('index')
    rowInfo = @translationList[index]
    value = $(e.target).val()
    @onTranslationChanged(rowInfo, value)

  onTranslationChanged: (rowInfo, value) ->

    #- Navigate down to where the translation will live
    base = @model.attributes

    for seg in rowInfo.path
      base = base[seg]

    base = base.i18n

    base[@selectedLanguage] ?= {}
    base = base[@selectedLanguage]

    if rowInfo.key.length > 1
      for seg in rowInfo.key[..-2]
        base[seg] ?= {}
        base = base[seg]

    #- Set the data in a non-kosher way

    base[rowInfo.key[rowInfo.key.length-1]] = value
    @model.saveBackup()

    #- Enable patch submit button

    @$el.find('#patch-submit').attr('disabled', null)
    @madeChanges = true

  onLanguageSelectChanged: (e) ->
    if @madeChanges
      return unless confirm('You have unsaved changes!')
    return if @hush
    @selectedLanguage = $(e.target).val()
    if @selectedLanguage
      me.set('preferredLanguage', @selectedLanguage)
      me.patch()
    @madeChanges = false
    @model.set(@originalModel.clone().attributes)
    @render()

  onClickOpenPatchLink: (e) ->
    patchID = $(e.currentTarget).data('patch-id')
    patch = @patches.get(patchID)
    modal = new PatchModal(patch, @model)
    @openModalView(modal)

  onLeaveMessage: ->
    if @madeChanges
      return 'You have unsaved changes!'

  onSubmitPatch: (e) ->
    delta = @originalModel.getDeltaWith(@model)
    flattened = deltasLib.flattenDelta(delta)
    collection = _.string.underscored @model.constructor.className
    patch = new Patch({
      delta
      target: { collection, 'id': @model.id }
      commitMessage: "Diplomat submission for lang #{@selectedLanguage}: #{flattened.length} change(s)."
    })
    errors = patch.validate()
    button = $(e.target)
    button.attr('disabled', 'disabled')
    return button.text('Failed to Submit Changes') if errors
    res = patch.save(null, { url: "/db/#{collection}/#{@model.id}/patch" })
    return button.text('Failed to Submit Changes') unless res
    button.text('Submitting...')
    Promise.resolve(res)
    .then =>
      @savedBefore = true
      @madeChanges = false
      @patches.add(patch)
      @renderSelectors('#patches-col')
      button.text('Submit Changes')
    .catch =>
      button.text('Error Submitting Changes')
      @$el.find('#patch-submit').attr('disabled', null)
        
