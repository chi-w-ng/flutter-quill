import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:string_validator/string_validator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/documents/attribute.dart';
import '../models/documents/document.dart';
import '../models/documents/nodes/container.dart' as container_node;
import '../models/documents/nodes/embed.dart';
import '../models/documents/nodes/leaf.dart' as leaf;
import '../models/documents/nodes/line.dart';
import '../utils/string_helper.dart';
import 'box.dart';
import 'controller.dart';
import 'cursor.dart';
import 'default_styles.dart';
import 'delegate.dart';
import 'float_cursor.dart';
import 'image.dart';
import 'raw_editor.dart';
import 'text_selection.dart';
import 'video_app.dart';
import 'youtube_video_app.dart';

const linkPrefixes = [
  'mailto:', // email
  'tel:', // telephone
  'sms:', // SMS
  'callto:',
  'wtai:',
  'market:',
  'geopoint:',
  'ymsgr:',
  'msnim:',
  'gtalk:', // Google Talk
  'skype:',
  'sip:', // Lync
  'whatsapp:',
  'http'
];

abstract class EditorState extends State<RawEditor>
    implements TextSelectionDelegate {
  ScrollController get scrollController;

  RenderEditor? getRenderEditor();

  EditorTextSelectionOverlay? getSelectionOverlay();

  /// Controls the floating cursor animation when it is released.
  /// The floating cursor is animated to merge with the regular cursor.
  AnimationController get floatingCursorResetController;

  bool showToolbar();

  void requestKeyboard();
}

/// Base interface for editable render objects.
abstract class RenderAbstractEditor implements TextLayoutMetrics {
  TextSelection selectWordAtPosition(TextPosition position);

  TextSelection selectLineAtPosition(TextPosition position);

  /// Returns preferred line height at specified `position` in text.
  double preferredLineHeight(TextPosition position);

  /// Returns [Rect] for caret in local coordinates
  ///
  /// Useful to enforce visibility of full caret at given position
  Rect getLocalRectForCaret(TextPosition position);

  /// Returns the local coordinates of the endpoints of the given selection.
  ///
  /// If the selection is collapsed (and therefore occupies a single point), the
  /// returned list is of length one. Otherwise, the selection is not collapsed
  /// and the returned list is of length two. In this case, however, the two
  /// points might actually be co-located (e.g., because of a bidirectional
  /// selection that contains some text but whose ends meet in the middle).
  TextPosition getPositionForOffset(Offset offset);

  /// Returns the local coordinates of the endpoints of the given selection.
  ///
  /// If the selection is collapsed (and therefore occupies a single point), the
  /// returned list is of length one. Otherwise, the selection is not collapsed
  /// and the returned list is of length two. In this case, however, the two
  /// points might actually be co-located (e.g., because of a bidirectional
  /// selection that contains some text but whose ends meet in the middle).
  List<TextSelectionPoint> getEndpointsForSelection(
      TextSelection textSelection);

  /// Sets the screen position of the floating cursor and the text position
  /// closest to the cursor.
  /// `resetLerpValue` drives the size of the floating cursor.
  /// See [EditorState.floatingCursorResetController].
  void setFloatingCursor(FloatingCursorDragState dragState,
      Offset lastBoundedOffset, TextPosition lastTextPosition,
      {double? resetLerpValue});

  /// If [ignorePointer] is false (the default) then this method is called by
  /// the internal gesture recognizer's [TapGestureRecognizer.onTapDown]
  /// callback.
  ///
  /// When [ignorePointer] is true, an ancestor widget must respond to tap
  /// down events by calling this method.
  void handleTapDown(TapDownDetails details);

  /// Selects the set words of a paragraph in a given range of global positions.
  ///
  /// The first and last endpoints of the selection will always be at the
  /// beginning and end of a word respectively.
  ///
  /// {@macro flutter.rendering.editable.select}
  void selectWordsInRange(
    Offset from,
    Offset to,
    SelectionChangedCause cause,
  );

  /// Move the selection to the beginning or end of a word.
  ///
  /// {@macro flutter.rendering.editable.select}
  void selectWordEdge(SelectionChangedCause cause);

  /// Select text between the global positions [from] and [to].
  void selectPositionAt(Offset from, Offset to, SelectionChangedCause cause);

  /// Select a word around the location of the last tap down.
  ///
  /// {@macro flutter.rendering.editable.select}
  void selectWord(SelectionChangedCause cause);

  /// Move selection to the location of the last tap down.
  ///
  /// {@template flutter.rendering.editable.select}
  /// This method is mainly used to translate user inputs in global positions
  /// into a [TextSelection]. When used in conjunction with a [EditableText],
  /// the selection change is fed back into [TextEditingController.selection].
  ///
  /// If you have a [TextEditingController], it's generally easier to
  /// programmatically manipulate its `value` or `selection` directly.
  /// {@endtemplate}
  void selectPosition(SelectionChangedCause cause);
}

String _standardizeImageUrl(String url) {
  if (url.contains('base64')) {
    return url.split(',')[1];
  }
  return url;
}

bool _isMobile() => io.Platform.isAndroid || io.Platform.isIOS;

Widget defaultEmbedBuilder(
    BuildContext context, leaf.Embed node, bool readOnly) {
  assert(!kIsWeb, 'Please provide EmbedBuilder for Web');
  switch (node.value.type) {
    case 'image':
      final imageUrl = _standardizeImageUrl(node.value.data);

      final style = node.style.attributes['style'];
      if (_isMobile() && style != null) {
        final _attrs = parseKeyValuePairs(style.value.toString(),
            {'mobileWidth', 'mobileHeight', 'mobileMargin', 'mobileAlignment'});
        if (_attrs.isNotEmpty) {
          assert(
              _attrs['mobileWidth'] != null && _attrs['mobileHeight'] != null,
              'mobileWidth and mobileHeight must be specified');
          final w = double.parse(_attrs['mobileWidth']!);
          final h = double.parse(_attrs['mobileHeight']!);
          final m = _attrs['mobileMargin'] == null
              ? 0.0
              : double.parse(_attrs['mobileMargin']!);
          final a = getAlignment(_attrs['mobileAlignment']);
          return Padding(
              padding: EdgeInsets.all(m),
              child: imageUrl.startsWith('http')
                  ? Image.network(imageUrl, width: w, height: h, alignment: a)
                  : isBase64(imageUrl)
                      ? Image.memory(base64.decode(imageUrl),
                          width: w, height: h, alignment: a)
                      : Image.file(io.File(imageUrl),
                          width: w, height: h, alignment: a));
        }
      }
      return imageUrl.startsWith('http')
          ? Image.network(imageUrl)
          : isBase64(imageUrl)
              ? Image.memory(base64.decode(imageUrl))
              : Image.file(io.File(imageUrl));
    case 'video':
      final videoUrl = node.value.data;
      if (videoUrl.contains('youtube.com') || videoUrl.contains('youtu.be')) {
        return YoutubeVideoApp(
            videoUrl: videoUrl, context: context, readOnly: readOnly);
      }
      return VideoApp(videoUrl: videoUrl, context: context, readOnly: readOnly);
    default:
      throw UnimplementedError(
        'Embeddable type "${node.value.type}" is not supported by default '
        'embed builder of QuillEditor. You must pass your own builder function '
        'to embedBuilder property of QuillEditor or QuillField widgets.',
      );
  }
}

class QuillEditor extends StatefulWidget {
  const QuillEditor(
      {required this.controller,
      required this.focusNode,
      required this.scrollController,
      required this.scrollable,
      required this.padding,
      required this.autoFocus,
      required this.readOnly,
      required this.expands,
      this.showCursor,
      this.paintCursorAboveText,
      this.placeholder,
      this.enableInteractiveSelection = true,
      this.scrollBottomInset = 0,
      this.minHeight,
      this.maxHeight,
      this.customStyles,
      this.textCapitalization = TextCapitalization.sentences,
      this.keyboardAppearance = Brightness.light,
      this.scrollPhysics,
      this.onLaunchUrl,
      this.onTapDown,
      this.onTapUp,
      this.onSingleLongTapStart,
      this.onSingleLongTapMoveUpdate,
      this.onSingleLongTapEnd,
      this.embedBuilder = defaultEmbedBuilder,
      this.customStyleBuilder,
      this.floatingCursorDisabled = false,
      Key? key});

  factory QuillEditor.basic({
    required QuillController controller,
    required bool readOnly,
    Brightness? keyboardAppearance,
  }) {
    return QuillEditor(
      controller: controller,
      scrollController: ScrollController(),
      scrollable: true,
      focusNode: FocusNode(),
      autoFocus: true,
      readOnly: readOnly,
      expands: false,
      padding: EdgeInsets.zero,
      keyboardAppearance: keyboardAppearance ?? Brightness.light,
    );
  }

  final QuillController controller;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final bool scrollable;
  final double scrollBottomInset;
  final EdgeInsetsGeometry padding;
  final bool autoFocus;
  final bool? showCursor;
  final bool? paintCursorAboveText;
  final bool readOnly;
  final String? placeholder;
  final bool enableInteractiveSelection;
  final double? minHeight;
  final double? maxHeight;
  final DefaultStyles? customStyles;
  final bool expands;
  final TextCapitalization textCapitalization;
  final Brightness keyboardAppearance;
  final ScrollPhysics? scrollPhysics;
  final ValueChanged<String>? onLaunchUrl;
  // Returns whether gesture is handled
  final bool Function(
      TapDownDetails details, TextPosition Function(Offset offset))? onTapDown;

  // Returns whether gesture is handled
  final bool Function(
      TapUpDetails details, TextPosition Function(Offset offset))? onTapUp;

  // Returns whether gesture is handled
  final bool Function(
          LongPressStartDetails details, TextPosition Function(Offset offset))?
      onSingleLongTapStart;

  // Returns whether gesture is handled
  final bool Function(LongPressMoveUpdateDetails details,
      TextPosition Function(Offset offset))? onSingleLongTapMoveUpdate;
  // Returns whether gesture is handled
  final bool Function(
          LongPressEndDetails details, TextPosition Function(Offset offset))?
      onSingleLongTapEnd;

  final EmbedBuilder embedBuilder;
  final CustomStyleBuilder? customStyleBuilder;

  final bool floatingCursorDisabled;

  @override
  _QuillEditorState createState() => _QuillEditorState();
}

class _QuillEditorState extends State<QuillEditor>
    implements EditorTextSelectionGestureDetectorBuilderDelegate {
  final GlobalKey<EditorState> _editorKey = GlobalKey<EditorState>();
  late EditorTextSelectionGestureDetectorBuilder
      _selectionGestureDetectorBuilder;

  @override
  void initState() {
    super.initState();
    _selectionGestureDetectorBuilder =
        _QuillEditorSelectionGestureDetectorBuilder(this);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectionTheme = TextSelectionTheme.of(context);

    TextSelectionControls textSelectionControls;
    bool paintCursorAboveText;
    bool cursorOpacityAnimates;
    Offset? cursorOffset;
    Color? cursorColor;
    Color selectionColor;
    Radius? cursorRadius;

    switch (theme.platform) {
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        textSelectionControls = materialTextSelectionControls;
        paintCursorAboveText = false;
        cursorOpacityAnimates = false;
        cursorColor ??= selectionTheme.cursorColor ?? theme.colorScheme.primary;
        selectionColor = selectionTheme.selectionColor ??
            theme.colorScheme.primary.withOpacity(0.40);
        break;
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        final cupertinoTheme = CupertinoTheme.of(context);
        textSelectionControls = cupertinoTextSelectionControls;
        paintCursorAboveText = true;
        cursorOpacityAnimates = true;
        cursorColor ??=
            selectionTheme.cursorColor ?? cupertinoTheme.primaryColor;
        selectionColor = selectionTheme.selectionColor ??
            cupertinoTheme.primaryColor.withOpacity(0.40);
        cursorRadius ??= const Radius.circular(2);
        cursorOffset = Offset(
            iOSHorizontalOffset / MediaQuery.of(context).devicePixelRatio, 0);
        break;
      default:
        throw UnimplementedError();
    }

    final child = RawEditor(
      key: _editorKey,
      controller: widget.controller,
      focusNode: widget.focusNode,
      scrollController: widget.scrollController,
      scrollable: widget.scrollable,
      scrollBottomInset: widget.scrollBottomInset,
      padding: widget.padding,
      readOnly: widget.readOnly,
      placeholder: widget.placeholder,
      onLaunchUrl: widget.onLaunchUrl,
      toolbarOptions: ToolbarOptions(
        copy: widget.enableInteractiveSelection,
        cut: widget.enableInteractiveSelection,
        paste: widget.enableInteractiveSelection,
        selectAll: widget.enableInteractiveSelection,
      ),
      showSelectionHandles: theme.platform == TargetPlatform.iOS ||
          theme.platform == TargetPlatform.android,
      showCursor: widget.showCursor,
      cursorStyle: CursorStyle(
        color: cursorColor,
        backgroundColor: Colors.grey,
        width: 2,
        radius: cursorRadius,
        offset: cursorOffset,
        paintAboveText: widget.paintCursorAboveText ?? paintCursorAboveText,
        opacityAnimates: cursorOpacityAnimates,
      ),
      textCapitalization: widget.textCapitalization,
      minHeight: widget.minHeight,
      maxHeight: widget.maxHeight,
      customStyles: widget.customStyles,
      expands: widget.expands,
      autoFocus: widget.autoFocus,
      selectionColor: selectionColor,
      selectionCtrls: textSelectionControls,
      keyboardAppearance: widget.keyboardAppearance,
      enableInteractiveSelection: widget.enableInteractiveSelection,
      scrollPhysics: widget.scrollPhysics,
      embedBuilder: widget.embedBuilder,
      customStyleBuilder: widget.customStyleBuilder,
      floatingCursorDisabled: widget.floatingCursorDisabled,
    );

    return _selectionGestureDetectorBuilder.build(
      HitTestBehavior.translucent,
      child,
    );
  }

  @override
  GlobalKey<EditorState> getEditableTextKey() {
    return _editorKey;
  }

  @override
  bool getForcePressEnabled() {
    return false;
  }

  @override
  bool getSelectionEnabled() {
    return widget.enableInteractiveSelection;
  }

  void _requestKeyboard() {
    _editorKey.currentState!.requestKeyboard();
  }
}

class _QuillEditorSelectionGestureDetectorBuilder
    extends EditorTextSelectionGestureDetectorBuilder {
  _QuillEditorSelectionGestureDetectorBuilder(this._state) : super(_state);

  final _QuillEditorState _state;

  @override
  void onForcePressStart(ForcePressDetails details) {
    super.onForcePressStart(details);
    if (delegate.getSelectionEnabled() && shouldShowSelectionToolbar) {
      getEditor()!.showToolbar();
    }
  }

  @override
  void onForcePressEnd(ForcePressDetails details) {}

  @override
  void onSingleLongTapMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_state.widget.onSingleLongTapMoveUpdate != null) {
      final renderEditor = getRenderEditor();
      if (renderEditor != null) {
        if (_state.widget.onSingleLongTapMoveUpdate!(
            details, renderEditor.getPositionForOffset)) {
          return;
        }
      }
    }
    if (!delegate.getSelectionEnabled()) {
      return;
    }
    switch (Theme.of(_state.context).platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        getRenderEditor()!.selectPositionAt(
          details.globalPosition,
          null,
          SelectionChangedCause.longPress,
        );
        break;
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        getRenderEditor()!.selectWordsInRange(
          details.globalPosition - details.offsetFromOrigin,
          details.globalPosition,
          SelectionChangedCause.longPress,
        );
        break;
      default:
        throw 'Invalid platform';
    }
  }

  bool _onTapping(TapUpDetails details) {
    if (_state.widget.controller.document.isEmpty()) {
      return false;
    }
    final pos = getRenderEditor()!.getPositionForOffset(details.globalPosition);
    final result =
        getEditor()!.widget.controller.document.queryChild(pos.offset);
    if (result.node == null) {
      return false;
    }
    final line = result.node as Line;
    final segmentResult = line.queryChild(result.offset, false);
    if (segmentResult.node == null) {
      if (line.length == 1) {
        getEditor()!.widget.controller.updateSelection(
            TextSelection.collapsed(offset: pos.offset), ChangeSource.LOCAL);
        return true;
      }
      return false;
    }
    final segment = segmentResult.node as leaf.Leaf;
    if (segment.style.containsKey(Attribute.link.key)) {
      var launchUrl = getEditor()!.widget.onLaunchUrl;
      launchUrl ??= _launchUrl;
      String? link = segment.style.attributes[Attribute.link.key]!.value;
      if (getEditor()!.widget.readOnly && link != null) {
        link = link.trim();
        if (!linkPrefixes
            .any((linkPrefix) => link!.toLowerCase().startsWith(linkPrefix))) {
          link = 'https://$link';
        }
        launchUrl(link);
      }
      return false;
    }
    if (getEditor()!.widget.readOnly && segment.value is BlockEmbed) {
      final blockEmbed = segment.value as BlockEmbed;
      if (blockEmbed.type == 'image') {
        final imageUrl = _standardizeImageUrl(blockEmbed.data);
        Navigator.push(
          getEditor()!.context,
          MaterialPageRoute(
            builder: (context) => ImageTapWrapper(
              imageProvider: imageUrl.startsWith('http')
                  ? NetworkImage(imageUrl)
                  : isBase64(imageUrl)
                      ? Image.memory(base64.decode(imageUrl))
                          as ImageProvider<Object>?
                      : FileImage(io.File(imageUrl)),
            ),
          ),
        );
      }
    }

    return false;
  }

  Future<void> _launchUrl(String url) async {
    await launch(url);
  }

  @override
  void onTapDown(TapDownDetails details) {
    if (_state.widget.onTapDown != null) {
      final renderEditor = getRenderEditor();
      if (renderEditor != null) {
        if (_state.widget.onTapDown!(
            details, renderEditor.getPositionForOffset)) {
          return;
        }
      }
    }
    super.onTapDown(details);
  }

  @override
  void onSingleTapUp(TapUpDetails details) {
    if (_state.widget.onTapUp != null) {
      final renderEditor = getRenderEditor();
      if (renderEditor != null) {
        if (_state.widget.onTapUp!(
            details, renderEditor.getPositionForOffset)) {
          return;
        }
      }
    }

    getEditor()!.hideToolbar();

    final positionSelected = _onTapping(details);

    if (delegate.getSelectionEnabled() && !positionSelected) {
      switch (Theme.of(_state.context).platform) {
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
          switch (details.kind) {
            case PointerDeviceKind.mouse:
            case PointerDeviceKind.stylus:
            case PointerDeviceKind.invertedStylus:
              getRenderEditor()!.selectPosition(SelectionChangedCause.tap);
              break;
            case PointerDeviceKind.touch:
            case PointerDeviceKind.unknown:
              getRenderEditor()!.selectWordEdge(SelectionChangedCause.tap);
              break;
          }
          break;
        case TargetPlatform.android:
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.windows:
          getRenderEditor()!.selectPosition(SelectionChangedCause.tap);
          break;
      }
    }
    _state._requestKeyboard();
  }

  @override
  void onSingleLongTapStart(LongPressStartDetails details) {
    if (_state.widget.onSingleLongTapStart != null) {
      final renderEditor = getRenderEditor();
      if (renderEditor != null) {
        if (_state.widget.onSingleLongTapStart!(
            details, renderEditor.getPositionForOffset)) {
          return;
        }
      }
    }

    if (delegate.getSelectionEnabled()) {
      switch (Theme.of(_state.context).platform) {
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
          getRenderEditor()!.selectPositionAt(
            details.globalPosition,
            null,
            SelectionChangedCause.longPress,
          );
          break;
        case TargetPlatform.android:
        case TargetPlatform.fuchsia:
        case TargetPlatform.linux:
        case TargetPlatform.windows:
          getRenderEditor()!.selectWord(SelectionChangedCause.longPress);
          Feedback.forLongPress(_state.context);
          break;
        default:
          throw 'Invalid platform';
      }
    }
  }

  @override
  void onSingleLongTapEnd(LongPressEndDetails details) {
    if (_state.widget.onSingleLongTapEnd != null) {
      final renderEditor = getRenderEditor();
      if (renderEditor != null) {
        if (_state.widget.onSingleLongTapEnd!(
            details, renderEditor.getPositionForOffset)) {
          return;
        }
      }
    }
    super.onSingleLongTapEnd(details);
  }
}

/// Signature for the callback that reports when the user changes the selection
/// (including the cursor location).
///
/// Used by [RenderEditor.onSelectionChanged].
typedef TextSelectionChangedHandler = void Function(
    TextSelection selection, SelectionChangedCause cause);

// The padding applied to text field. Used to determine the bounds when
// moving the floating cursor.
const EdgeInsets _kFloatingCursorAddedMargin = EdgeInsets.fromLTRB(4, 4, 4, 5);

// The additional size on the x and y axis with which to expand the prototype
// cursor to render the floating cursor in pixels.
const EdgeInsets _kFloatingCaretSizeIncrease =
    EdgeInsets.symmetric(horizontal: 0.5, vertical: 1);

class RenderEditor extends RenderEditableContainerBox
    with RelayoutWhenSystemFontsChangeMixin
    implements RenderAbstractEditor {
  RenderEditor(
      ViewportOffset? offset,
      List<RenderEditableBox>? children,
      TextDirection textDirection,
      double scrollBottomInset,
      EdgeInsetsGeometry padding,
      this.document,
      this.selection,
      this._hasFocus,
      this.onSelectionChanged,
      this._startHandleLayerLink,
      this._endHandleLayerLink,
      EdgeInsets floatingCursorAddedMargin,
      this._cursorController,
      this.floatingCursorDisabled)
      : super(
          children,
          document.root,
          textDirection,
          scrollBottomInset,
          padding,
        );

  final CursorCont _cursorController;
  final bool floatingCursorDisabled;

  Document document;
  TextSelection selection;
  bool _hasFocus = false;
  LayerLink _startHandleLayerLink;
  LayerLink _endHandleLayerLink;
  TextSelectionChangedHandler onSelectionChanged;
  final ValueNotifier<bool> _selectionStartInViewport =
      ValueNotifier<bool>(true);

  ValueListenable<bool> get selectionStartInViewport =>
      _selectionStartInViewport;

  ValueListenable<bool> get selectionEndInViewport => _selectionEndInViewport;
  final ValueNotifier<bool> _selectionEndInViewport = ValueNotifier<bool>(true);

  void _updateSelectionExtentsVisibility(Offset effectiveOffset) {
    final visibleRegion = Offset.zero & size;
    final startPosition =
        TextPosition(offset: selection.start, affinity: selection.affinity);
    final startOffset = _getOffsetForCaret(startPosition);
    // TODO(justinmc): https://github.com/flutter/flutter/issues/31495
    // Check if the selection is visible with an approximation because a
    // difference between rounded and unrounded values causes the caret to be
    // reported as having a slightly (< 0.5) negative y offset. This rounding
    // happens in paragraph.cc's layout and TextPainer's
    // _applyFloatingPointHack. Ideally, the rounding mismatch will be fixed and
    // this can be changed to be a strict check instead of an approximation.
    const visibleRegionSlop = 0.5;
    _selectionStartInViewport.value = visibleRegion
        .inflate(visibleRegionSlop)
        .contains(startOffset + effectiveOffset);

    final endPosition =
        TextPosition(offset: selection.end, affinity: selection.affinity);
    final endOffset = _getOffsetForCaret(endPosition);
    _selectionEndInViewport.value = visibleRegion
        .inflate(visibleRegionSlop)
        .contains(endOffset + effectiveOffset);
  }

  // returns offset relative to this at which the caret will be painted
  // given a global TextPosition
  Offset _getOffsetForCaret(TextPosition position) {
    final child = childAtPosition(position);
    final childPosition = child.globalToLocalPosition(position);
    final boxParentData = child.parentData as BoxParentData;
    final localOffsetForCaret = child.getOffsetForCaret(childPosition);
    return boxParentData.offset + localOffsetForCaret;
  }

  void setDocument(Document doc) {
    if (document == doc) {
      return;
    }
    document = doc;
    markNeedsLayout();
  }

  void setHasFocus(bool h) {
    if (_hasFocus == h) {
      return;
    }
    _hasFocus = h;
    markNeedsSemanticsUpdate();
  }

  Offset get _paintOffset => Offset(0, -(offset?.pixels ?? 0.0));

  ViewportOffset? get offset => _offset;
  ViewportOffset? _offset;

  set offset(ViewportOffset? value) {
    if (_offset == value) return;
    if (attached) _offset?.removeListener(markNeedsPaint);
    _offset = value;
    if (attached) _offset?.addListener(markNeedsPaint);
    markNeedsLayout();
  }

  void setSelection(TextSelection t) {
    if (selection == t) {
      return;
    }
    selection = t;
    markNeedsPaint();
  }

  void setStartHandleLayerLink(LayerLink value) {
    if (_startHandleLayerLink == value) {
      return;
    }
    _startHandleLayerLink = value;
    markNeedsPaint();
  }

  void setEndHandleLayerLink(LayerLink value) {
    if (_endHandleLayerLink == value) {
      return;
    }
    _endHandleLayerLink = value;
    markNeedsPaint();
  }

  void setScrollBottomInset(double value) {
    if (scrollBottomInset == value) {
      return;
    }
    scrollBottomInset = value;
    markNeedsPaint();
  }

  @override
  List<TextSelectionPoint> getEndpointsForSelection(
      TextSelection textSelection) {
    if (textSelection.isCollapsed) {
      final child = childAtPosition(textSelection.extent);
      final localPosition = TextPosition(
          offset: textSelection.extentOffset - child.getContainer().offset);
      final localOffset = child.getOffsetForCaret(localPosition);
      final parentData = child.parentData as BoxParentData;
      return <TextSelectionPoint>[
        TextSelectionPoint(
            Offset(0, child.preferredLineHeight(localPosition)) +
                localOffset +
                parentData.offset,
            null)
      ];
    }

    final baseNode = _container.queryChild(textSelection.start, false).node;

    var baseChild = firstChild;
    while (baseChild != null) {
      if (baseChild.getContainer() == baseNode) {
        break;
      }
      baseChild = childAfter(baseChild);
    }
    assert(baseChild != null);

    final baseParentData = baseChild!.parentData as BoxParentData;
    final baseSelection =
        localSelection(baseChild.getContainer(), textSelection, true);
    var basePoint = baseChild.getBaseEndpointForSelection(baseSelection);
    basePoint = TextSelectionPoint(
        basePoint.point + baseParentData.offset, basePoint.direction);

    final extentNode = _container.queryChild(textSelection.end, false).node;
    RenderEditableBox? extentChild = baseChild;
    while (extentChild != null) {
      if (extentChild.getContainer() == extentNode) {
        break;
      }
      extentChild = childAfter(extentChild);
    }
    assert(extentChild != null);

    final extentParentData = extentChild!.parentData as BoxParentData;
    final extentSelection =
        localSelection(extentChild.getContainer(), textSelection, true);
    var extentPoint =
        extentChild.getExtentEndpointForSelection(extentSelection);
    extentPoint = TextSelectionPoint(
        extentPoint.point + extentParentData.offset, extentPoint.direction);

    return <TextSelectionPoint>[basePoint, extentPoint];
  }

  Offset? _lastTapDownPosition;

  @override
  void handleTapDown(TapDownDetails details) {
    _lastTapDownPosition = details.globalPosition;
  }

  @override
  void selectWordsInRange(
    Offset from,
    Offset? to,
    SelectionChangedCause cause,
  ) {
    final firstPosition = getPositionForOffset(from);
    final firstWord = selectWordAtPosition(firstPosition);
    final lastWord =
        to == null ? firstWord : selectWordAtPosition(getPositionForOffset(to));

    _handleSelectionChange(
      TextSelection(
        baseOffset: firstWord.base.offset,
        extentOffset: lastWord.extent.offset,
        affinity: firstWord.affinity,
      ),
      cause,
    );
  }

  void _handleSelectionChange(
    TextSelection nextSelection,
    SelectionChangedCause cause,
  ) {
    final focusingEmpty = nextSelection.baseOffset == 0 &&
        nextSelection.extentOffset == 0 &&
        !_hasFocus;
    if (nextSelection == selection &&
        cause != SelectionChangedCause.keyboard &&
        !focusingEmpty) {
      return;
    }
    onSelectionChanged(nextSelection, cause);
  }

  @override
  void selectWordEdge(SelectionChangedCause cause) {
    assert(_lastTapDownPosition != null);
    final position = getPositionForOffset(_lastTapDownPosition!);
    final child = childAtPosition(position);
    final nodeOffset = child.getContainer().offset;
    final localPosition = TextPosition(
      offset: position.offset - nodeOffset,
      affinity: position.affinity,
    );
    final localWord = child.getWordBoundary(localPosition);
    final word = TextRange(
      start: localWord.start + nodeOffset,
      end: localWord.end + nodeOffset,
    );
    if (position.offset - word.start <= 1) {
      _handleSelectionChange(
        TextSelection.collapsed(offset: word.start),
        cause,
      );
    } else {
      _handleSelectionChange(
        TextSelection.collapsed(
            offset: word.end, affinity: TextAffinity.upstream),
        cause,
      );
    }
  }

  @override
  void selectPositionAt(
    Offset from,
    Offset? to,
    SelectionChangedCause cause,
  ) {
    final fromPosition = getPositionForOffset(from);
    final toPosition = to == null ? null : getPositionForOffset(to);

    var baseOffset = fromPosition.offset;
    var extentOffset = fromPosition.offset;
    if (toPosition != null) {
      baseOffset = math.min(fromPosition.offset, toPosition.offset);
      extentOffset = math.max(fromPosition.offset, toPosition.offset);
    }

    final newSelection = TextSelection(
      baseOffset: baseOffset,
      extentOffset: extentOffset,
      affinity: fromPosition.affinity,
    );
    _handleSelectionChange(newSelection, cause);
  }

  @override
  void selectWord(SelectionChangedCause cause) {
    selectWordsInRange(_lastTapDownPosition!, null, cause);
  }

  @override
  void selectPosition(SelectionChangedCause cause) {
    selectPositionAt(_lastTapDownPosition!, null, cause);
  }

  @override
  TextSelection selectWordAtPosition(TextPosition position) {
    final word = getWordBoundary(position);
    // When long-pressing past the end of the text, we want a collapsed cursor.
    if (position.offset >= word.end) {
      return TextSelection.fromPosition(position);
    }
    return TextSelection(baseOffset: word.start, extentOffset: word.end);
  }

  @override
  TextSelection selectLineAtPosition(TextPosition position) {
    final line = getLineAtOffset(position);

    // When long-pressing past the end of the text, we want a collapsed cursor.
    if (position.offset >= line.end) {
      return TextSelection.fromPosition(position);
    }
    return TextSelection(baseOffset: line.start, extentOffset: line.end);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_hasFocus &&
        _cursorController.show.value &&
        !_cursorController.style.paintAboveText) {
      _paintFloatingCursor(context, offset);
    }
    defaultPaint(context, offset);
    _updateSelectionExtentsVisibility(offset + _paintOffset);
    _paintHandleLayers(context, getEndpointsForSelection(selection));

    if (_hasFocus &&
        _cursorController.show.value &&
        _cursorController.style.paintAboveText) {
      _paintFloatingCursor(context, offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }

  void _paintHandleLayers(
      PaintingContext context, List<TextSelectionPoint> endpoints) {
    var startPoint = endpoints[0].point;
    startPoint = Offset(
      startPoint.dx.clamp(0.0, size.width),
      startPoint.dy.clamp(0.0, size.height),
    );
    context.pushLayer(
      LeaderLayer(link: _startHandleLayerLink, offset: startPoint),
      super.paint,
      Offset.zero,
    );
    if (endpoints.length == 2) {
      var endPoint = endpoints[1].point;
      endPoint = Offset(
        endPoint.dx.clamp(0.0, size.width),
        endPoint.dy.clamp(0.0, size.height),
      );
      context.pushLayer(
        LeaderLayer(link: _endHandleLayerLink, offset: endPoint),
        super.paint,
        Offset.zero,
      );
    }
  }

  @override
  double preferredLineHeight(TextPosition position) {
    final child = childAtPosition(position);
    return child.preferredLineHeight(
        TextPosition(offset: position.offset - child.getContainer().offset));
  }

  @override
  TextPosition getPositionForOffset(Offset offset) {
    final local = globalToLocal(offset);
    final child = childAtOffset(local)!;

    final parentData = child.parentData as BoxParentData;
    final localOffset = local - parentData.offset;
    final localPosition = child.getPositionForOffset(localOffset);
    return TextPosition(
      offset: localPosition.offset + child.getContainer().offset,
      affinity: localPosition.affinity,
    );
  }

  /// Returns the y-offset of the editor at which [selection] is visible.
  ///
  /// The offset is the distance from the top of the editor and is the minimum
  /// from the current scroll position until [selection] becomes visible.
  /// Returns null if [selection] is already visible.
  double? getOffsetToRevealCursor(
      double viewportHeight, double scrollOffset, double offsetInViewport) {
    final endpoints = getEndpointsForSelection(selection);

    // when we drag the right handle, we should get the last point
    TextSelectionPoint endpoint;
    if (selection.isCollapsed) {
      endpoint = endpoints.first;
    } else {
      if (selection is DragTextSelection) {
        endpoint = (selection as DragTextSelection).first
            ? endpoints.first
            : endpoints.last;
      } else {
        endpoint = endpoints.first;
      }
    }

    final child = childAtPosition(selection.extent);
    const kMargin = 8.0;

    final caretTop = endpoint.point.dy -
        child.preferredLineHeight(TextPosition(
            offset:
                selection.extentOffset - child.getContainer().documentOffset)) -
        kMargin +
        offsetInViewport +
        scrollBottomInset;
    final caretBottom =
        endpoint.point.dy + kMargin + offsetInViewport + scrollBottomInset;
    double? dy;
    if (caretTop < scrollOffset) {
      dy = caretTop;
    } else if (caretBottom > scrollOffset + viewportHeight) {
      dy = caretBottom - viewportHeight;
    }
    if (dy == null) {
      return null;
    }
    return math.max(dy, 0);
  }

  @override
  Rect getLocalRectForCaret(TextPosition position) {
    final targetChild = childAtPosition(position);
    final localPosition = targetChild.globalToLocalPosition(position);

    final childLocalRect = targetChild.getLocalRectForCaret(localPosition);

    final boxParentData = targetChild.parentData as BoxParentData;
    return childLocalRect.shift(Offset(0, boxParentData.offset.dy));
  }

  // Start floating cursor

  FloatingCursorPainter get _floatingCursorPainter => FloatingCursorPainter(
        floatingCursorRect: _floatingCursorRect,
        style: _cursorController.style,
      );

  bool _floatingCursorOn = false;
  Rect? _floatingCursorRect;

  TextPosition get floatingCursorTextPosition => _floatingCursorTextPosition;
  late TextPosition _floatingCursorTextPosition;

  // The relative origin in relation to the distance the user has theoretically
  // dragged the floating cursor offscreen.
  // This value is used to account for the difference
  // in the rendering position and the raw offset value.
  Offset _relativeOrigin = Offset.zero;
  Offset? _previousOffset;
  bool _resetOriginOnLeft = false;
  bool _resetOriginOnRight = false;
  bool _resetOriginOnTop = false;
  bool _resetOriginOnBottom = false;

  /// Returns the position within the editor closest to the raw cursor offset.
  Offset calculateBoundedFloatingCursorOffset(
      Offset rawCursorOffset, double preferredLineHeight) {
    var deltaPosition = Offset.zero;
    final topBound = _kFloatingCursorAddedMargin.top;
    final bottomBound =
        size.height - preferredLineHeight + _kFloatingCursorAddedMargin.bottom;
    final leftBound = _kFloatingCursorAddedMargin.left;
    final rightBound = size.width - _kFloatingCursorAddedMargin.right;

    if (_previousOffset != null) {
      deltaPosition = rawCursorOffset - _previousOffset!;
    }

    // If the raw cursor offset has gone off an edge,
    // we want to reset the relative origin of
    // the dragging when the user drags back into the field.
    if (_resetOriginOnLeft && deltaPosition.dx > 0) {
      _relativeOrigin =
          Offset(rawCursorOffset.dx - leftBound, _relativeOrigin.dy);
      _resetOriginOnLeft = false;
    } else if (_resetOriginOnRight && deltaPosition.dx < 0) {
      _relativeOrigin =
          Offset(rawCursorOffset.dx - rightBound, _relativeOrigin.dy);
      _resetOriginOnRight = false;
    }
    if (_resetOriginOnTop && deltaPosition.dy > 0) {
      _relativeOrigin =
          Offset(_relativeOrigin.dx, rawCursorOffset.dy - topBound);
      _resetOriginOnTop = false;
    } else if (_resetOriginOnBottom && deltaPosition.dy < 0) {
      _relativeOrigin =
          Offset(_relativeOrigin.dx, rawCursorOffset.dy - bottomBound);
      _resetOriginOnBottom = false;
    }

    final currentX = rawCursorOffset.dx - _relativeOrigin.dx;
    final currentY = rawCursorOffset.dy - _relativeOrigin.dy;
    final double adjustedX =
        math.min(math.max(currentX, leftBound), rightBound);
    final double adjustedY =
        math.min(math.max(currentY, topBound), bottomBound);
    final adjustedOffset = Offset(adjustedX, adjustedY);

    if (currentX < leftBound && deltaPosition.dx < 0) {
      _resetOriginOnLeft = true;
    } else if (currentX > rightBound && deltaPosition.dx > 0) {
      _resetOriginOnRight = true;
    }
    if (currentY < topBound && deltaPosition.dy < 0) {
      _resetOriginOnTop = true;
    } else if (currentY > bottomBound && deltaPosition.dy > 0) {
      _resetOriginOnBottom = true;
    }

    _previousOffset = rawCursorOffset;

    return adjustedOffset;
  }

  @override
  void setFloatingCursor(FloatingCursorDragState dragState,
      Offset boundedOffset, TextPosition textPosition,
      {double? resetLerpValue}) {
    if (floatingCursorDisabled) return;

    if (dragState == FloatingCursorDragState.Start) {
      _relativeOrigin = Offset.zero;
      _previousOffset = null;
      _resetOriginOnBottom = false;
      _resetOriginOnTop = false;
      _resetOriginOnRight = false;
      _resetOriginOnBottom = false;
    }
    _floatingCursorOn = dragState != FloatingCursorDragState.End;
    if (_floatingCursorOn) {
      _floatingCursorTextPosition = textPosition;
      final sizeAdjustment = resetLerpValue != null
          ? EdgeInsets.lerp(
              _kFloatingCaretSizeIncrease, EdgeInsets.zero, resetLerpValue)!
          : _kFloatingCaretSizeIncrease;
      final child = childAtPosition(textPosition);
      final caretPrototype =
          child.getCaretPrototype(child.globalToLocalPosition(textPosition));
      _floatingCursorRect =
          sizeAdjustment.inflateRect(caretPrototype).shift(boundedOffset);
      _cursorController
          .setFloatingCursorTextPosition(_floatingCursorTextPosition);
    } else {
      _floatingCursorRect = null;
      _cursorController.setFloatingCursorTextPosition(null);
    }
  }

  void _paintFloatingCursor(PaintingContext context, Offset offset) {
    _floatingCursorPainter.paint(context.canvas);
  }

  // End floating cursor

  // Start TextLayoutMetrics implementation

  /// Return a [TextSelection] containing the line of the given [TextPosition].
  @override
  TextSelection getLineAtOffset(TextPosition position) {
    final child = childAtPosition(position);
    final nodeOffset = child.getContainer().offset;
    final localPosition = TextPosition(
        offset: position.offset - nodeOffset, affinity: position.affinity);
    final localLineRange = child.getLineBoundary(localPosition);
    final line = TextRange(
      start: localLineRange.start + nodeOffset,
      end: localLineRange.end + nodeOffset,
    );
    return TextSelection(baseOffset: line.start, extentOffset: line.end);
  }

  @override
  TextRange getWordBoundary(TextPosition position) {
    final child = childAtPosition(position);
    final nodeOffset = child.getContainer().offset;
    final localPosition = TextPosition(
        offset: position.offset - nodeOffset, affinity: position.affinity);
    final localWord = child.getWordBoundary(localPosition);
    return TextRange(
      start: localWord.start + nodeOffset,
      end: localWord.end + nodeOffset,
    );
  }

  /// Returns the TextPosition above the given offset into the text.
  ///
  /// If the offset is already on the first line, the offset of the first
  /// character will be returned.
  @override
  TextPosition getTextPositionAbove(TextPosition position) {
    final child = childAtPosition(position);
    final localPosition = TextPosition(
        offset: position.offset - child.getContainer().documentOffset);

    var newPosition = child.getPositionAbove(localPosition);

    if (newPosition == null) {
      // There was no text above in the current child, check the direct
      // sibling.
      final sibling = childBefore(child);
      if (sibling == null) {
        // reached beginning of the document, move to the
        // first character
        newPosition = const TextPosition(offset: 0);
      } else {
        final caretOffset = child.getOffsetForCaret(localPosition);
        final testPosition =
            TextPosition(offset: sibling.getContainer().length - 1);
        final testOffset = sibling.getOffsetForCaret(testPosition);
        final finalOffset = Offset(caretOffset.dx, testOffset.dy);
        final siblingPosition = sibling.getPositionForOffset(finalOffset);
        newPosition = TextPosition(
            offset:
                sibling.getContainer().documentOffset + siblingPosition.offset);
      }
    } else {
      newPosition = TextPosition(
          offset: child.getContainer().documentOffset + newPosition.offset);
    }
    return newPosition;
  }

  /// Returns the TextPosition below the given offset into the text.
  ///
  /// If the offset is already on the last line, the offset of the last
  /// character will be returned.
  @override
  TextPosition getTextPositionBelow(TextPosition position) {
    final child = childAtPosition(position);
    final localPosition = TextPosition(
        offset: position.offset - child.getContainer().documentOffset);

    var newPosition = child.getPositionBelow(localPosition);

    if (newPosition == null) {
      // There was no text above in the current child, check the direct
      // sibling.
      final sibling = childAfter(child);
      if (sibling == null) {
        // reached beginning of the document, move to the
        // last character
        newPosition = TextPosition(offset: document.length - 1);
      } else {
        final caretOffset = child.getOffsetForCaret(localPosition);
        const testPosition = TextPosition(offset: 0);
        final testOffset = sibling.getOffsetForCaret(testPosition);
        final finalOffset = Offset(caretOffset.dx, testOffset.dy);
        final siblingPosition = sibling.getPositionForOffset(finalOffset);
        newPosition = TextPosition(
            offset:
                sibling.getContainer().documentOffset + siblingPosition.offset);
      }
    } else {
      newPosition = TextPosition(
          offset: child.getContainer().documentOffset + newPosition.offset);
    }
    return newPosition;
  }

  // End TextLayoutMetrics implementation

  @override
  void systemFontsDidChange() {
    super.systemFontsDidChange();
    markNeedsLayout();
  }

  void debugAssertLayoutUpToDate() {
    // no-op?
    // this assert was added by Flutter TextEditingActionTarge
    // so we have to comply here.
  }
}

class EditableContainerParentData
    extends ContainerBoxParentData<RenderEditableBox> {}

class RenderEditableContainerBox extends RenderBox
    with
        ContainerRenderObjectMixin<RenderEditableBox,
            EditableContainerParentData>,
        RenderBoxContainerDefaultsMixin<RenderEditableBox,
            EditableContainerParentData> {
  RenderEditableContainerBox(
    List<RenderEditableBox>? children,
    this._container,
    this.textDirection,
    this.scrollBottomInset,
    this._padding,
  ) : assert(_padding.isNonNegative) {
    addAll(children);
  }

  container_node.Container _container;
  TextDirection textDirection;
  EdgeInsetsGeometry _padding;
  double scrollBottomInset;
  EdgeInsets? _resolvedPadding;

  container_node.Container getContainer() {
    return _container;
  }

  void setContainer(container_node.Container c) {
    if (_container == c) {
      return;
    }
    _container = c;
    markNeedsLayout();
  }

  EdgeInsetsGeometry getPadding() => _padding;

  void setPadding(EdgeInsetsGeometry value) {
    assert(value.isNonNegative);
    if (_padding == value) {
      return;
    }
    _padding = value;
    _markNeedsPaddingResolution();
  }

  EdgeInsets? get resolvedPadding => _resolvedPadding;

  void _resolvePadding() {
    if (_resolvedPadding != null) {
      return;
    }
    _resolvedPadding = _padding.resolve(textDirection);
    _resolvedPadding = _resolvedPadding!.copyWith(left: _resolvedPadding!.left);

    assert(_resolvedPadding!.isNonNegative);
  }

  RenderEditableBox childAtPosition(TextPosition position) {
    assert(firstChild != null);

    final targetNode = _container.queryChild(position.offset, false).node;

    var targetChild = firstChild;
    while (targetChild != null) {
      if (targetChild.getContainer() == targetNode) {
        break;
      }
      final newChild = childAfter(targetChild);
      if (newChild == null) {
        break;
      }
      targetChild = newChild;
    }
    if (targetChild == null) {
      throw 'targetChild should not be null';
    }
    return targetChild;
  }

  void _markNeedsPaddingResolution() {
    _resolvedPadding = null;
    markNeedsLayout();
  }

  RenderEditableBox? childAtOffset(Offset offset) {
    assert(firstChild != null);
    _resolvePadding();

    if (offset.dy <= _resolvedPadding!.top) {
      return firstChild;
    }
    if (offset.dy >= size.height - _resolvedPadding!.bottom) {
      return lastChild;
    }

    var child = firstChild;
    final dx = -offset.dx;
    var dy = _resolvedPadding!.top;
    while (child != null) {
      if (child.size.contains(offset.translate(dx, -dy))) {
        return child;
      }
      dy += child.size.height;
      child = childAfter(child);
    }
    throw 'No child';
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is EditableContainerParentData) {
      return;
    }

    child.parentData = EditableContainerParentData();
  }

  @override
  void performLayout() {
    assert(constraints.hasBoundedWidth);
    _resolvePadding();
    assert(_resolvedPadding != null);

    var mainAxisExtent = _resolvedPadding!.top;
    var child = firstChild;
    final innerConstraints =
        BoxConstraints.tightFor(width: constraints.maxWidth)
            .deflate(_resolvedPadding!);
    while (child != null) {
      child.layout(innerConstraints, parentUsesSize: true);
      final childParentData = (child.parentData as EditableContainerParentData)
        ..offset = Offset(_resolvedPadding!.left, mainAxisExtent);
      mainAxisExtent += child.size.height;
      assert(child.parentData == childParentData);
      child = childParentData.nextSibling;
    }
    mainAxisExtent += _resolvedPadding!.bottom;
    size = constraints.constrain(Size(constraints.maxWidth, mainAxisExtent));

    assert(size.isFinite);
  }

  double _getIntrinsicCrossAxis(double Function(RenderBox child) childSize) {
    var extent = 0.0;
    var child = firstChild;
    while (child != null) {
      extent = math.max(extent, childSize(child));
      final childParentData = child.parentData as EditableContainerParentData;
      child = childParentData.nextSibling;
    }
    return extent;
  }

  double _getIntrinsicMainAxis(double Function(RenderBox child) childSize) {
    var extent = 0.0;
    var child = firstChild;
    while (child != null) {
      extent += childSize(child);
      final childParentData = child.parentData as EditableContainerParentData;
      child = childParentData.nextSibling;
    }
    return extent;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    _resolvePadding();
    return _getIntrinsicCrossAxis((child) {
      final childHeight = math.max<double>(
          0, height - _resolvedPadding!.top + _resolvedPadding!.bottom);
      return child.getMinIntrinsicWidth(childHeight) +
          _resolvedPadding!.left +
          _resolvedPadding!.right;
    });
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    _resolvePadding();
    return _getIntrinsicCrossAxis((child) {
      final childHeight = math.max<double>(
          0, height - _resolvedPadding!.top + _resolvedPadding!.bottom);
      return child.getMaxIntrinsicWidth(childHeight) +
          _resolvedPadding!.left +
          _resolvedPadding!.right;
    });
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    _resolvePadding();
    return _getIntrinsicMainAxis((child) {
      final childWidth = math.max<double>(
          0, width - _resolvedPadding!.left + _resolvedPadding!.right);
      return child.getMinIntrinsicHeight(childWidth) +
          _resolvedPadding!.top +
          _resolvedPadding!.bottom;
    });
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    _resolvePadding();
    return _getIntrinsicMainAxis((child) {
      final childWidth = math.max<double>(
          0, width - _resolvedPadding!.left + _resolvedPadding!.right);
      return child.getMaxIntrinsicHeight(childWidth) +
          _resolvedPadding!.top +
          _resolvedPadding!.bottom;
    });
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) {
    _resolvePadding();
    return defaultComputeDistanceToFirstActualBaseline(baseline)! +
        _resolvedPadding!.top;
  }
}
