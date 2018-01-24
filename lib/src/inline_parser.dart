// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'ast.dart';
import 'document.dart';
import 'emojis.dart';
import 'util.dart';

/// Maintains the internal state needed to parse inline span elements in
/// Markdown.
class InlineParser {
  static final List<InlineSyntax> _defaultSyntaxes =
      new List<InlineSyntax>.unmodifiable(<InlineSyntax>[
    new EmailAutolinkSyntax(),
    new AutolinkSyntax(),
    new LineBreakSyntax(),
    new LinkSyntax(),
    new ImageSyntax(),
    // Allow any punctuation to be escaped.
    new EscapeSyntax(),
    // "*" surrounded by spaces is left alone.
    new TextSyntax(r' \* '),
    // "_" surrounded by spaces is left alone.
    new TextSyntax(r' _ '),
    // Leave already-encoded HTML entities alone. Ensures we don't turn
    // "&amp;" into "&amp;amp;"
    new TextSyntax(r'&[#a-zA-Z0-9]*;'),
    // Encode "&".
    new TextSyntax(r'&', sub: '&amp;'),
    // Encode "<". (Why not encode ">" too? Gruber is toying with us.)
    new TextSyntax(r'<', sub: '&lt;'),
    // Parse "**strong**" and "*emphasis*" tags.
    new TagSyntax(r'\*+', requiresDelimiterRun: true),
    // Parse "__strong__" and "_emphasis_" tags.
    new TagSyntax(r'_+', requiresDelimiterRun: true),
    new CodeSyntax(),
    // We will add the LinkSyntax once we know about the specific link resolver.
  ]);

  /// The string of Markdown being parsed.
  final String source;

  /// The Markdown document this parser is parsing.
  final Document document;

  final List<InlineSyntax> syntaxes = <InlineSyntax>[];

  /// The current read position.
  int pos = 0;

  /// Starting position of the last unconsumed text.
  int start = 0;

  final List<TagState> _stack;

  InlineParser(this.source, this.document) : _stack = <TagState>[] {
    // User specified syntaxes are the first syntaxes to be evaluated.
    syntaxes.addAll(document.inlineSyntaxes);

    var documentHasCustomInlineSyntaxes = document.inlineSyntaxes
        .any((s) => !document.extensionSet.inlineSyntaxes.contains(s));

    // This first RegExp matches plain text to accelerate parsing. It's written
    // so that it does not match any prefix of any following syntaxes. Most
    // Markdown is plain text, so it's faster to match one RegExp per 'word'
    // rather than fail to match all the following RegExps at each non-syntax
    // character position.
    if (documentHasCustomInlineSyntaxes) {
      // We should be less aggressive in blowing past "words".
      syntaxes.add(new TextSyntax(r'[A-Za-z0-9]+\s'));
    } else {
      syntaxes.add(new TextSyntax(r'[ \tA-Za-z0-9]*[A-Za-z0-9]\s'));
    }

    syntaxes.addAll(_defaultSyntaxes);

    // Custom link resolvers go after the generic text syntax.
    syntaxes.insertAll(1, [
      new LinkSyntax(linkResolver: document.linkResolver),
      new ImageSyntax(linkResolver: document.imageLinkResolver)
    ]);
  }

  List<Node> parse() {
    // Make a fake top tag to hold the results.
    _stack.add(new TagState(0, 0, null, null));

    while (!isDone) {
      var matched = false;

      // See if any of the current tags on the stack match. We don't allow tags
      // of the same kind to nest, so this takes priority over other possible
      // matches.
      for (var i = _stack.length - 1; i > 0; i--) {
        if (_stack[i].tryMatch(this)) {
          matched = true;
          break;
        }
      }

      if (matched) continue;

      // See if the current text matches any defined markdown syntax.
      for (var syntax in syntaxes) {
        if (syntax.tryMatch(this)) {
          matched = true;
          break;
        }
      }

      if (matched) continue;

      // If we got here, it's just text.
      advanceBy(1);
    }

    // Unwind any unmatched tags and get the results.
    return _stack[0].close(this, null);
  }

  void writeText() {
    writeTextRange(start, pos);
    start = pos;
  }

  void writeTextRange(int start, int end) {
    if (end <= start) return;

    var text = source.substring(start, end);
    var nodes = _stack.last.children;

    // If the previous node is text too, just append.
    if (nodes.length > 0 && nodes.last is Text) {
      var textNode = nodes.last as Text;
      nodes[nodes.length - 1] = new Text('${textNode.text}$text');
    } else {
      nodes.add(new Text(text));
    }
  }

  void addNode(Node node) {
    _stack.last.children.add(node);
  }

  bool get isDone => pos == source.length;

  void advanceBy(int length) {
    pos += length;
  }

  void consume(int length) {
    pos += length;
    start = pos;
  }
}

/// Represents one kind of Markdown tag that can be parsed.
abstract class InlineSyntax {
  final RegExp pattern;

  InlineSyntax(String pattern) : pattern = new RegExp(pattern, multiLine: true);

  /// Tries to match at the parser's current position.
  ///
  /// Returns whether or not the pattern successfully matched.
  bool tryMatch(InlineParser parser) {
    var startMatch = pattern.matchAsPrefix(parser.source, parser.pos);
    if (startMatch != null) {
      // Write any existing plain text up to this point.
      parser.writeText();

      if (onMatch(parser, startMatch)) parser.consume(startMatch[0].length);
      return true;
    }

    return false;
  }

  /// Processes [match], adding nodes to [parser] and possibly advancing
  /// [parser].
  ///
  /// Returns whether the caller should advance [parser] by `match[0].length`.
  bool onMatch(InlineParser parser, Match match);
}

/// Represents a hard line break.
class LineBreakSyntax extends InlineSyntax {
  LineBreakSyntax() : super(r'(?:\\|  +)\n');

  /// Create a void <br> element.
  bool onMatch(InlineParser parser, Match match) {
    parser.addNode(new Element.empty('br'));
    return true;
  }
}

/// Matches stuff that should just be passed through as straight text.
class TextSyntax extends InlineSyntax {
  final String substitute;

  TextSyntax(String pattern, {String sub})
      : substitute = sub,
        super(pattern);

  bool onMatch(InlineParser parser, Match match) {
    if (substitute == null) {
      // Just use the original matched text.
      parser.advanceBy(match[0].length);
      return false;
    }

    // Insert the substitution.
    parser.addNode(new Text(substitute));
    return true;
  }
}

/// Escape punctuation preceded by a backslash.
class EscapeSyntax extends InlineSyntax {
  EscapeSyntax() : super(r'''\\[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]''');

  bool onMatch(InlineParser parser, Match match) {
    // Insert the substitution.
    parser.addNode(new Text(match[0][1]));
    return true;
  }
}

/// Leave inline HTML tags alone, from
/// [CommonMark 0.22](http://spec.commonmark.org/0.22/#raw-html).
///
/// This is not actually a good definition (nor CommonMark's) of an HTML tag,
/// but it is fast. It will leave text like `<a href='hi">` alone, which is
/// incorrect.
///
/// TODO(srawlins): improve accuracy while ensuring performance, once
/// Markdown benchmarking is more mature.
class InlineHtmlSyntax extends TextSyntax {
  InlineHtmlSyntax() : super(r'<[/!?]?[A-Za-z][A-Za-z0-9-]*(?: [^>]*)?>');
}

/// Matches autolinks like `<foo@bar.example.com>`.
///
/// See <http://spec.commonmark.org/0.28/#email-address>.
class EmailAutolinkSyntax extends InlineSyntax {
  static final _email =
      r'''[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}'''
      r'''[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*''';

  EmailAutolinkSyntax() : super('<($_email)>');

  bool onMatch(InlineParser parser, Match match) {
    var url = match[1];
    var anchor = new Element.text('a', escapeHtml(url));
    anchor.attributes['href'] = Uri.encodeFull('mailto:$url');
    parser.addNode(anchor);

    return true;
  }
}

/// Matches autolinks like `<http://foo.com>`.
class AutolinkSyntax extends InlineSyntax {
  AutolinkSyntax() : super(r'<(([a-zA-Z][a-zA-Z\-\+\.]+):(?://)?[^\s>]*)>');

  bool onMatch(InlineParser parser, Match match) {
    var url = match[1];
    var anchor = new Element.text('a', escapeHtml(url));
    anchor.attributes['href'] = Uri.encodeFull(url);
    parser.addNode(anchor);

    return true;
  }
}

/// Matches autolinks like `http://foo.com`.
class AutolinkExtensionSyntax extends InlineSyntax {
  static const START = r'(?:^|[\s*_~(>])';
  static const SCHEME = r'(?:(?:https?|ftp):\/\/|www\.)';
  static const DOMAIN = r'[a-zA-Z_\-.]+';
  static const PATH = r'[^\s<]*';
  // static const TRUNCATING_PUNCTUATION_NEG = r'[^\s<\?\!\.\,\:\*\_\~]';
  static const TRUNCATING_PUNCTUATION_NEG = r'';

  static const TRUNCATING_PUNCTUATION_POS = r'[?!.,:*_~]';

  AutolinkExtensionSyntax()
      : super('$START(($SCHEME)($DOMAIN)($PATH))$TRUNCATING_PUNCTUATION_NEG');

  @override
  bool tryMatch(InlineParser parser) {
    var startMatch = pattern.matchAsPrefix(parser.source.substring(parser.pos));
    if (startMatch != null) {
      // Write any existing plain text up to this point.
      parser.writeText();

      if (onMatch(parser, startMatch)) parser.consume(startMatch[0].length);
      return true;
    }

    return false;
  }

  @override
  bool onMatch(InlineParser parser, Match match) {
    var url = match[1];
    var href = url;
    var matchLength = url.length;

    if (url.startsWith(new RegExp(r'(\s|\>)'))) {
      url = url.substring(1, url.length - 1);
      href = href.substring(1, href.length - 1);
      parser.pos++;
      matchLength--;
    }

    /** Prevent accidental standard autolink matches */
    if (url.endsWith('>') && parser.source[parser.pos - 1] == '<') {
      return false;
    }

    /**
     * When an autolink ends in ), we scan the entire autolink for the total
     * number of parentheses. If there is a greater number of closing
     * parentheses than opening ones, we don’t consider the last character
     * part of the autolink, in order to facilitate including an autolink
     * inside a parenthesis:
     * https://github.github.com/gfm/#example-600
     */
    if (url.endsWith(')')) {
      final opening = new RegExp(r'\(').allMatches(url).length;
      final closing = new RegExp(r'\)').allMatches(url).length;
      if (closing > opening) {
        url = url.substring(0, url.length - 1);
        href = href.substring(0, href.length - 1);
        matchLength--;
      }
    }

    /**
     * Trailing punctuation (specifically, ?, !, ., ,, :, *, _, and ~) will
     * not be considered part of the autolink, though they may be included
     * in the interior of the link:
     * https://github.github.com/gfm/#example-599
     */
    final trailingPunc =
        new RegExp('$TRUNCATING_PUNCTUATION_POS*' + r'$').firstMatch(url);
    if (trailingPunc != null) {
      url = url.substring(0, url.length - trailingPunc[0].length);
      href = href.substring(0, href.length - trailingPunc[0].length);
      matchLength -= trailingPunc[0].length;
    }

    /**
     * If an autolink ends in a semicolon (;), we check to see if it appears
     * to resemble an
     * [entity reference](https://github.github.com/gfm/#entity-references);
     * if the preceding text is & followed by one or more alphanumeric
     * characters. If so, it is excluded from the autolink:
     * https://github.github.com/gfm/#example-602
     */
    if (url.endsWith(';')) {
      final entityRef = new RegExp(r'\&[a-zA-Z0-9]+;$').firstMatch(url);
      if (entityRef != null) {
        // Strip out HTML entity reference
        url = url.substring(0, url.length - entityRef[0].length);
        href = href.substring(0, href.length - entityRef[0].length);
        matchLength -= entityRef[0].length;
      }
    }

    /** The scheme http will be inserted automatically */
    if (!href.startsWith(new RegExp(r'(?:https?|ftp)\:\/\/'))) {
      href = 'http://$href';
    }

    final anchor = new Element.text('a', escapeHtml(url));
    anchor.attributes['href'] = Uri.encodeFull(href);
    parser.addNode(anchor);

    parser.consume(matchLength);
    return false;
  }
}

class _DelimiterRun {
  static final String punctuation = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';
  // TODO(srawlins): Unicode whitespace
  static final String whitespace = ' \t\r\n';

  final String char;
  final int length;
  final bool isLeftFlanking;
  final bool isRightFlanking;
  final bool isPrecededByPunctuation;
  final bool isFollowedByPunctuation;

  _DelimiterRun._(
      {this.char,
      this.length,
      this.isLeftFlanking,
      this.isRightFlanking,
      this.isPrecededByPunctuation,
      this.isFollowedByPunctuation});

  static _DelimiterRun tryParse(InlineParser parser, int runStart, int runEnd) {
    bool leftFlanking,
        rightFlanking,
        precededByPunctuation,
        followedByPunctuation;
    String preceding, following;
    if (runStart == 0) {
      rightFlanking = false;
      preceding = '\n';
    } else {
      preceding = parser.source.substring(runStart - 1, runStart);
    }
    precededByPunctuation = punctuation.contains(preceding);

    if (runEnd == parser.source.length - 1) {
      leftFlanking = false;
      following = '\n';
    } else {
      following = parser.source.substring(runEnd + 1, runEnd + 2);
    }
    followedByPunctuation = punctuation.contains(following);

    // http://spec.commonmark.org/0.28/#left-flanking-delimiter-run
    if (whitespace.contains(following)) {
      leftFlanking = false;
    } else {
      leftFlanking = !followedByPunctuation ||
          whitespace.contains(preceding) ||
          precededByPunctuation;
    }

    // http://spec.commonmark.org/0.28/#right-flanking-delimiter-run
    if (whitespace.contains(preceding)) {
      rightFlanking = false;
    } else {
      rightFlanking = !precededByPunctuation ||
          whitespace.contains(following) ||
          followedByPunctuation;
    }

    if (!leftFlanking && !rightFlanking) {
      // Could not parse a delimiter run.
      return null;
    }

    return new _DelimiterRun._(
        char: parser.source.substring(runStart, runStart + 1),
        length: runEnd - runStart + 1,
        isLeftFlanking: leftFlanking,
        isRightFlanking: rightFlanking,
        isPrecededByPunctuation: precededByPunctuation,
        isFollowedByPunctuation: followedByPunctuation);
  }

  String toString() =>
      '<char: $char, length: $length, isLeftFlanking: $isLeftFlanking, '
      'isRightFlanking: $isRightFlanking>';

  // Whether a delimiter in this run can open emphasis or strong emphasis.
  bool get canOpen =>
      isLeftFlanking &&
      (char == '*' || !isRightFlanking || isPrecededByPunctuation);

  // Whether a delimiter in this run can close emphasis or strong emphasis.
  bool get canClose =>
      isRightFlanking &&
      (char == '*' || !isLeftFlanking || isFollowedByPunctuation);
}

/// Matches syntax that has a pair of tags and becomes an element, like `*` for
/// `<em>`. Allows nested tags.
class TagSyntax extends InlineSyntax {
  final RegExp endPattern;
  final bool requiresDelimiterRun;

  TagSyntax(String pattern, {String end, this.requiresDelimiterRun: false})
      : endPattern = new RegExp((end != null) ? end : pattern, multiLine: true),
        super(pattern);

  bool onMatch(InlineParser parser, Match match) {
    var runLength = match.group(0).length;
    var matchStart = parser.pos;
    var matchEnd = parser.pos + runLength - 1;
    var delimiterRun = _DelimiterRun.tryParse(parser, matchStart, matchEnd);
    if (delimiterRun != null && delimiterRun.canOpen) {
      parser._stack
          .add(new TagState(parser.pos, matchEnd + 1, this, delimiterRun));
      return true;
    } else {
      parser.advanceBy(runLength);
      return false;
    }
  }

  bool onMatchEnd(InlineParser parser, Match match, TagState state) {
    var runLength = match.group(0).length;
    var matchStart = parser.pos;
    var matchEnd = parser.pos + runLength - 1;
    var openingRunLength = state.endPos - state.startPos;
    var delimiterRun = _DelimiterRun.tryParse(parser, matchStart, matchEnd);
    if (!delimiterRun.isRightFlanking) {
      return false;
    }

    if (openingRunLength == 1 && runLength == 1) {
      parser.addNode(new Element('em', state.children));
    } else if (openingRunLength == 1 && runLength > 1) {
      parser.addNode(new Element('em', state.children));
      parser.pos = parser.pos - (runLength - 1);
      parser.start = parser.pos;
    } else if (openingRunLength > 1 && runLength == 1) {
      parser._stack.add(
          new TagState(state.startPos, state.endPos - 1, this, delimiterRun));
      parser.addNode(new Element('em', state.children));
    } else if (openingRunLength == 2 && runLength == 2) {
      parser.addNode(new Element('strong', state.children));
    } else if (openingRunLength == 2 && runLength > 2) {
      parser.addNode(new Element('strong', state.children));
      parser.pos = parser.pos - (runLength - 2);
      parser.start = parser.pos;
    } else if (openingRunLength > 2 && runLength == 2) {
      parser._stack.add(
          new TagState(state.startPos, state.endPos - 2, this, delimiterRun));
      parser.addNode(new Element('strong', state.children));
    } else if (openingRunLength > 2 && runLength > 2) {
      parser._stack.add(
          new TagState(state.startPos, state.endPos - 2, this, delimiterRun));
      parser.addNode(new Element('strong', state.children));
      parser.pos = parser.pos - (runLength - 2);
      parser.start = parser.pos;
    }

    return true;
  }
}

/// Matches strikethrough syntax according to the GFM spec.
class StrikethroughSyntax extends TagSyntax {
  StrikethroughSyntax() : super('~+', requiresDelimiterRun: true);

  @override
  bool onMatchEnd(InlineParser parser, Match match, TagState state) {
    var runLength = match.group(0).length;
    var matchStart = parser.pos;
    var matchEnd = parser.pos + runLength - 1;
    var delimiterRun = _DelimiterRun.tryParse(parser, matchStart, matchEnd);
    if (!delimiterRun.isRightFlanking) {
      return false;
    }

    parser.addNode(new Element('del', state.children));
    return true;
  }
}

/// Matches inline links like `[blah][id]` and `[blah](url)`.
class LinkSyntax extends TagSyntax {
  final Resolver linkResolver;

  /// The regex for the end of a link.
  ///
  /// This handles both reference-style and inline-style links as well as
  /// optional titles for inline links. To make that a bit more palatable, this
  /// breaks it into pieces.
  static String get _linkPattern {
    var refLink = r'\[([^\]]*)\]'; // `[id]` reflink id.
    var title = r'(?:\s*"([^"]+?)"\s*|)'; // Optional title in quotes.
    var inlineLink = '\\((\\S*?)$title\\)'; // `(url "title")` link.
    return '\](?:($refLink|$inlineLink)|)';

    // The groups matched by this are:
    // 1: Will be non-empty if it's either a ref or inline link. Will be empty
    //    if it's just a bare pair of square brackets with nothing after them.
    // 2: Contains the id inside [] for a reference-style link.
    // 3: Contains the URL for an inline link.
    // 4: Contains the title, if present, for an inline link.
  }

  LinkSyntax({this.linkResolver, String pattern: r'\['})
      : super(pattern, end: _linkPattern);

  Node createNode(InlineParser parser, Match match, TagState state) {
    if (match[1] == null) {
      // Try for a shortcut reference link, like `[foo]`.
      var element = _createElement(parser, match, state);
      if (element != null) return element;

      // If we didn't match refLink or inlineLink, and it's not a _shortcut_
      // reflink, then it means it isn't a normal Markdown link at all. Instead,
      // we allow users of the library to specify a special resolver function
      // ([linkResolver]) that may choose to handle this. Otherwise, it's just
      // treated as plain text.
      if (linkResolver == null) return null;

      // Treat the contents as unparsed text even if they happen to match. This
      // way, we can handle things like [LINK_WITH_UNDERSCORES] as a link and
      // not get confused by the emphasis.
      var textToResolve = parser.source.substring(state.endPos, parser.pos);

      // See if we have a resolver that will generate a link for us.
      return linkResolver(textToResolve);
    } else {
      return _createElement(parser, match, state);
    }
  }

  /// Given that [match] has matched both a title and URL, creates an `<a>`
  /// [Element] for it.
  Element _createElement(InlineParser parser, Match match, TagState state) {
    var link = getLink(parser, match, state);
    if (link == null) return null;

    var element = new Element('a', state.children);

    element.attributes["href"] = escapeHtml(link.url);
    if (link.title != null) {
      element.attributes['title'] = escapeHtml(link.title);
    }

    return element;
  }

  /// Get the Link represented by [match].
  ///
  /// This method can return null, if the link is a reference link, and has no
  /// accompanying link reference definition.
  Link getLink(InlineParser parser, Match match, TagState state) {
    if (match[3] != null) {
      // Inline link like [foo](url).
      var url = match[3];
      var title = match[4];

      // For whatever reason, Markdown allows angle-bracketed URLs here.
      if (url.startsWith('<') && url.endsWith('>')) {
        url = url.substring(1, url.length - 1);
      }

      return new Link(null, url, title);
    } else {
      String id;
      String _contents() {
        var offset = pattern.pattern.length - 1;
        return parser.source.substring(state.startPos + offset, parser.pos);
      }

      // Reference link like [foo][bar].
      if (match[1] == null) {
        // There are no reference brackets ("shortcut reference link"), so infer
        // the id from the contents.
        id = _contents();
      } else if (match[2] == '') {
        // The id is empty ("[]") so infer it from the contents.
        id = _contents();
      } else {
        id = match[2];
      }

      // References are case-insensitive.
      id = id.toLowerCase();
      return parser.document.refLinks[id];
    }
  }

  bool onMatchEnd(InlineParser parser, Match match, TagState state) {
    var node = createNode(parser, match, state);
    if (node == null) return false;

    parser.addNode(node);
    return true;
  }
}

/// Matches images like `![alternate text](url "optional title")` and
/// `![alternate text][url reference]`.
class ImageSyntax extends LinkSyntax {
  ImageSyntax({Resolver linkResolver})
      : super(linkResolver: linkResolver, pattern: r'!\[');

  /// Creates an <img> element from the given complete [match].
  Element _createElement(InlineParser parser, Match match, TagState state) {
    var link = getLink(parser, match, state);
    if (link == null) return null;
    var image = new Element.empty("img");
    image.attributes["src"] = escapeHtml(link.url);
    image.attributes["alt"] = state?.textContent ?? '';

    if (link.title != null) {
      image.attributes["title"] = escapeHtml(link.title);
    }

    return image;
  }
}

/// Matches backtick-enclosed inline code blocks.
class CodeSyntax extends InlineSyntax {
  // This pattern matches:
  //
  // * a string of backticks (not followed by any more), followed by
  // * a non-greedy string of anything, including newlines, ending with anything
  //   except a backtick, followed by
  // * a string of backticks the same length as the first, not followed by any
  //   more.
  //
  // This conforms to the delimiters of inline code, both in Markdown.pl, and
  // CommonMark.
  static final String _pattern = r'(`+(?!`))((?:.|\n)*?[^`])\1(?!`)';

  CodeSyntax() : super(_pattern);

  bool tryMatch(InlineParser parser) {
    if (parser.pos > 0 && parser.source[parser.pos - 1] == '`') {
      // Not really a match! We can't just sneak past one backtick to try the
      // next character. An example of this situation would be:
      //
      //     before ``` and `` after.
      //             ^--parser.pos
      return false;
    }

    var match = pattern.matchAsPrefix(parser.source, parser.pos);
    if (match == null) {
      return false;
    }
    parser.writeText();
    if (onMatch(parser, match)) parser.consume(match[0].length);
    return true;
  }

  bool onMatch(InlineParser parser, Match match) {
    parser.addNode(new Element.text('code', escapeHtml(match[2].trim())));
    return true;
  }
}

/// Matches GitHub Markdown emoji syntax like `:smile:`.
///
/// There is no formal specification of GitHub's support for this colon-based
/// emoji support, so this syntax is based on the results of Markdown-enabled
/// text fields at github.com.
class EmojiSyntax extends InlineSyntax {
  // Emoji "aliases" are mostly limited to lower-case letters, numbers, and
  // underscores, but GitHub also supports `:+1:` and `:-1:`.
  EmojiSyntax() : super(':([a-z0-9_+-]+):');

  bool onMatch(InlineParser parser, Match match) {
    var alias = match[1];
    var emoji = emojis[alias];
    if (emoji == null) {
      parser.advanceBy(1);
      return false;
    }
    parser.addNode(new Text(emoji));

    return true;
  }
}

/// Keeps track of a currently open tag while it is being parsed.
///
/// The parser maintains a stack of these so it can handle nested tags.
class TagState {
  /// The point in the original source where this tag started.
  final int startPos;

  /// The point in the original source where open tag ended.
  final int endPos;

  /// The syntax that created this node.
  final TagSyntax syntax;

  /// The children of this node. Will be `null` for text nodes.
  final List<Node> children;

  final _DelimiterRun openingDelimiterRun;

  TagState(this.startPos, this.endPos, this.syntax, this.openingDelimiterRun)
      : children = <Node>[];

  /// Attempts to close this tag by matching the current text against its end
  /// pattern.
  bool tryMatch(InlineParser parser) {
    var endMatch = syntax.endPattern.matchAsPrefix(parser.source, parser.pos);
    if (endMatch == null) {
      return false;
    }

    if (!syntax.requiresDelimiterRun) {
      // Close the tag.
      close(parser, endMatch);
      return true;
    }

    var runLength = endMatch.group(0).length;
    var openingRunLength = endPos - startPos;
    var closingMatchStart = parser.pos;
    var closingMatchEnd = parser.pos + runLength - 1;
    var closingDelimiterRun =
        _DelimiterRun.tryParse(parser, closingMatchStart, closingMatchEnd);
    if (closingDelimiterRun != null && closingDelimiterRun.canClose) {
      // Emphasis rules #9 and #10:
      var oneRunOpensAndCloses =
          (openingDelimiterRun.canOpen && openingDelimiterRun.canClose) ||
              (closingDelimiterRun.canOpen && closingDelimiterRun.canClose);
      if (oneRunOpensAndCloses &&
          (openingRunLength + closingDelimiterRun.length) % 3 == 0) {
        return false;
      }
      // Close the tag.
      close(parser, endMatch);
      return true;
    } else {
      return false;
    }
  }

  /// Pops this tag off the stack, completes it, and adds it to the output.
  ///
  /// Will discard any unmatched tags that happen to be above it on the stack.
  /// If this is the last node in the stack, returns its children.
  List<Node> close(InlineParser parser, Match endMatch) {
    // If there are unclosed tags on top of this one when it's closed, that
    // means they are mismatched. Mismatched tags are treated as plain text in
    // markdown. So for each tag above this one, we write its start tag as text
    // and then adds its children to this one's children.
    var index = parser._stack.indexOf(this);

    // Remove the unmatched children.
    var unmatchedTags = parser._stack.sublist(index + 1);
    parser._stack.removeRange(index + 1, parser._stack.length);

    // Flatten them out onto this tag.
    for (var unmatched in unmatchedTags) {
      // Write the start tag as text.
      parser.writeTextRange(unmatched.startPos, unmatched.endPos);

      // Bequeath its children unto this tag.
      children.addAll(unmatched.children);
    }

    // Pop this off the stack.
    parser.writeText();
    parser._stack.removeLast();

    // If the stack is empty now, this is the special "results" node.
    if (parser._stack.length == 0) return children;

    // We are still parsing, so add this to its parent's children.
    if (syntax.onMatchEnd(parser, endMatch, this)) {
      parser.consume(endMatch[0].length);
    } else {
      // Didn't close correctly so revert to text.
      parser.start = startPos;
      parser.pos = parser.start;
      parser.advanceBy(endMatch[0].length);
    }

    return null;
  }

  String get textContent =>
      children.map((Node child) => child.textContent).join('');
}
