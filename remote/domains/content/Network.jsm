/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

"use strict";

var EXPORTED_SYMBOLS = ["Network"];

const { ContentProcessDomain } = ChromeUtils.import(
  "chrome://remote/content/domains/ContentProcessDomain.jsm"
);
const { ExtensionUtils } = ChromeUtils.import(
  "resource://gre/modules/ExtensionUtils.jsm"
);
const { XPCOMUtils } = ChromeUtils.import(
  "resource://gre/modules/XPCOMUtils.jsm"
);
XPCOMUtils.defineLazyGlobalGetters(this, ["InspectorUtils"]);

let contentDOMState = new WeakMap();

let nodeFilterConstants = {
  FILTER_ACCEPT: 1,
  FILTER_REJECT: 2,
  FILTER_SKIP: 3,

  SHOW_ALL: 0xffffffff,
  SHOW_ELEMENT: 0x00000001,
  SHOW_ATTRIBUTE: 0x00000002,
  SHOW_TEXT: 0x00000004,
  SHOW_CDATA_SECTION: 0x00000008,
  SHOW_ENTITY_REFERENCE: 0x00000010,
  SHOW_ENTITY: 0x00000020,
  SHOW_PROCESSING_INSTRUCTION: 0x00000040,
  SHOW_COMMENT: 0x00000080,
  SHOW_DOCUMENT: 0x00000100,
  SHOW_DOCUMENT_TYPE: 0x00000200,
  SHOW_DOCUMENT_FRAGMENT: 0x00000400,
  SHOW_NOTATION: 0x00000800,
};

// TODO: Remove some of these and add others like aria-*
const WHITELISTED_ATTRS = new Set([
  "accept",
  "accesskey",
  "align",
  "allow",
  "alt",
  "async",
  "autocapitalize",
  "autocomplete",
  "autofocus",
  "autoplay",
  "background",
  "Note",
  "bgcolor",
  "border",
  "buffered",
  "capture",
  "charset",
  "checked",
  "cite",
  "class",
  "code",
  "codebase",
  "color",
  "cols",
  "colspan",
  "content",
  "contenteditable",
  "contextmenu",
  "controls",
  "coords",
  "crossorigin",
  "csp",
  "data",
  "data",
  "datetime",
  "decoding",
  "default",
  "defer",
  "dir",
  "dirname",
  "disabled",
  "download",
  "draggable",
  "dropzone",
  "enctype",
  "enterkeyhint",
  "for",
  "form",
  "formaction",
  "formenctype",
  "formmethod",
  "formnovalidate",
  "formtarget",
  "headers",
  "height",
  "hidden",
  "high",
  "href",
  "hreflang",
  "http",
  "icon",
  // "id",
  "importance",
  "integrity",
  "intrinsicsize",
  "inputmode",
  "ismap",
  "itemprop",
  "keytype",
  "kind",
  "label",
  "lang",
  "language",
  "loading",
  "list",
  "loop",
  "low",
  "manifest",
  "max",
  "maxlength",
  "minlength",
  "media",
  "method",
  "min",
  "multiple",
  "muted",
  "name",
  "novalidate",
  "open",
  "optimum",
  "pattern",
  "ping",
  "placeholder",
  "poster",
  "preload",
  "radiogroup",
  "readonly",
  "referrerpolicy",
  "rel",
  "required",
  "reversed",
  "rows",
  "rowspan",
  "sandbox",
  "scope",
  "scoped",
  "selected",
  "shape",
  "size",
  "sizes",
  "slot",
  "span",
  "spellcheck",
  /*"src",
  "srcdoc",
  "srclang",
  "srcset",*/
  "start",
  "step",
  // "style",
  "summary",
  "tabindex",
  "target",
  "title",
  "translate",
  "type",
  "usemap",
  "value",
  "width",
  "wrap",
]);

class DOMBaker {
  constructor(networkDomain) {
    this.network = networkDomain;
    this.win = this.network.content;
    this.doc = this.win.document;

    this.$idsToNodes = new Map();
    this.$nodesToIds = new WeakMap();
    this.$nodesToVirtualNodes = new WeakMap();
  }

  static get events() {
    return ["focus", "blur", "input", "change"];
  }

  handleEvent(event) {
    const { $nodesToVirtualNodes } = this;
    let virtualNode = $nodesToVirtualNodes.get(event.target);
    if (!virtualNode) {
      // Event for a node we don't care about
      return;
    }

    // TODO: Send messages back to the client as needed
    console.log(event.type, event.target, event.target.value);

    const data = { target: virtualNode, type: event.type };
    switch (event.type) {
      case "focus": {
        break;
      }

      case "blur": {
        break;
      }

      case "change":
      case "input": {
        Object.assign(virtualNode, this.getVirtualNodeBase(event.target));
        break;
      }
    }

    // We probably don't need to emit every event, and we may sometimes want
    // to buffer them up before sending. For now let's just send this one.
    this.network.emitToUAServer({
      overriddenType: "events",
      data: [data],
    });
  }

  stopWatching() {
    // Do we actually need to bother if the document is going to be GC'ed?
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }

    for (let eventName of this.constructor.events) {
      this.win.removeEventListener(eventName, this, {
        mozSystemGroup: true,
        capture: true,
      });
    }
  }

  startWatching() {
    for (let eventName of this.constructor.events) {
      this.win.addEventListener(eventName, this, {
        mozSystemGroup: true,
        capture: true,
      });
    }
    const { $nodesToIds, $nodesToVirtualNodes } = this;

    const handleAddedNodes = ({ addedNodes }, bucket) => {
      let { $nodesToVirtualNodes } = this;

      // TODO: Should all added nodes be appended? Not sure how mutation observers work.
      //    No, see MutationRecord.previousSibling and MutationRecord.nextSibling.
      // I think we should probably actually worry about getting the vdom in sync (child reordering, etc)
      // and calculate a diff to send to the client separately.
      for (const node of addedNodes) {
        this.createVirtualNodeAndChildren(node);
        if ($nodesToVirtualNodes.has(node)) {
          // Also, this needs to invalidate styles since it could change selectors like
          // :empty
          bucket.added.push($nodesToVirtualNodes.get(node));
        }
      }
    };

    const handleRemovedNodes = ({ removedNodes }, bucket) => {
      for (const node of removedNodes) {
        const id = this.deregisterNode(node);
        if (id) {
          bucket.removed.push({ id, name: node.nodeName });
        }
      }
    };

    const handleAttributeChanged = ({ target }, bucket) => {
      const virtualNode = $nodesToVirtualNodes.get(target);

      if (virtualNode) {
        Object.assign(virtualNode, this.getVirtualNodeBase(target));
        // XXX: This really needs to invalidate children & siblings as well,
        // since it could change which CSS selectors are applying. For now we'll
        // just update this one
        bucket.updates.push({
          id: virtualNode.id,
          virtualNode,
        });
      }
    };

    const handleCharacterDataChanged = ({ target }, bucket) => {
      const virtualNode = $nodesToVirtualNodes.get(target);
      if (virtualNode) {
        // XXX: Share code for updating this with creation as much as possible.
        virtualNode.data = target.data;
        bucket.wrote.push({ id: virtualNode.id, data: target.data });
      }
    };

    const handleMutation = mutation => {
      // For node types we don't handle yet, don't forward to the client
      if (!$nodesToIds.get(mutation.target)) {
        return;
      }
      let target = {
        id: $nodesToIds.get(mutation.target),
        name: mutation.target.nodeName,
      };

      const bucket = {
        target,
        added: [],
        removed: [],
        wrote: [],
        updates: [],
      };
      switch (mutation.type) {
        case "childList":
          handleRemovedNodes(mutation, bucket);
          handleAddedNodes(mutation, bucket);
          break;
        case "attributes":
          handleAttributeChanged(mutation, bucket);
          break;
        case "characterData":
          handleCharacterDataChanged(mutation, bucket);
          break;
      }
      if (
        bucket.added.length ||
        bucket.removed.length ||
        bucket.wrote.length ||
        bucket.updates.length
      ) {
        return [bucket];
      }
      return [];
    };

    const onMutations = mutationList => {
      const mutations = mutationList.flatMap(handleMutation);
      if (mutations.length) {
        this.network.emitToUAServer({
          overriddenType: "mutations",
          data: mutations,
        });
      }
    };

    this.observer = new this.win.MutationObserver(onMutations);
    this.observer.observe(this.win.document.documentElement, {
      childList: true,
      attributes: true,
      characterData: true,
      subtree: true,
    });
  }
  deregisterNode(node) {
    const { $idsToNodes, $nodesToIds, $nodesToVirtualNodes } = this;
    const virtualNode = $nodesToVirtualNodes.get(node);
    if (!virtualNode) {
      return null;
    }
    $idsToNodes.delete(virtualNode.id);
    // XXX: Remove $nodesToIds and instead query for ID via virtual node
    $nodesToIds.delete(node);
    $nodesToVirtualNodes.delete(node);

    // Remove from parent
    let parentTree = $nodesToVirtualNodes.get(
      $idsToNodes.get(virtualNode.parentID)
    );
    if (parentTree) {
      let index = parentTree.children.indexOf(virtualNode);
      if (index == -1) {
        throw new Error("Child doesn't exist in parent. This shouldn't happen");
      }
      parentTree.children.splice(index, 1);
    }

    return virtualNode.id;
  }

  registerNode(node, virtualNode) {
    const { $idsToNodes, $nodesToIds, $nodesToVirtualNodes } = this;
    $idsToNodes.set(virtualNode.id, node);
    $nodesToIds.set(node, virtualNode.id);
    $nodesToVirtualNodes.set(node, virtualNode);
  }

  getSize(element) {
    let px = number => number.toFixed(2) + "px";
    let getBoundsWithoutFlushing = el =>
      el.ownerGlobal.windowUtils.getBoundsWithoutFlushing(el);
    let bounds = getBoundsWithoutFlushing(element);
    return {
      height: px(bounds.height),
      width: px(bounds.width),
      top: px(bounds.top),
      left: px(bounds.left),
    };
  }

  getStyles(node) {
    function hasVisitedState(node) {
      if (!node) {
        return false;
      }

      const NS_EVENT_STATE_VISITED = 1 << 24;

      return (
        !!(InspectorUtils.getContentState(node) & NS_EVENT_STATE_VISITED) ||
        InspectorUtils.hasPseudoClassLock(node, ":visited")
      );
    }
    function isAuthorStylesheet(sheet) {
      return sheet.parsingMode === "author";
    }

    // See also https://searchfox.org/mozilla-central/source/dom/chrome-webidl/InspectorUtils.webidl#17
    // InspectorUtils.getUsedFontFaces(searchRange, MAX_TEXT_RANGES);
    // We could also just read all computed styles if we wanted
    const domRules = InspectorUtils.getCSSStyleRules(
      node,
      null,
      hasVisitedState(node)
    );

    const rules = [];

    // getCSSStyleRules returns ordered from least-specific to
    // most-specific.
    for (let i = 0; i < domRules.length; i++) {
      const domRule = domRules[i];

      const isSystem = !isAuthorStylesheet(domRule.parentStyleSheet);
      if (isSystem) {
        continue;
      }

      let cssText = domRule.style.cssText;
      if (cssText.includes("url(")) {
        // This is really bad and only handles background-image specifically.
        // TODO: see what devtools does to resolve paths in style rules.
        let backgroundImage = node.ownerGlobal.getComputedStyle(node)[
          "background-image"
        ];
        cssText = cssText.replace(/url\((.*)\)/, `${backgroundImage}`);
      }
      rules.push(cssText);
    }

    rules.push(node.style.cssText);

    return rules.join("");
  }

  getVirtualNodeBase(node) {
    let virtualNodeBase = {
      tag: node.tagName.toLowerCase(),
      size: this.getSize(node),
      attributes: {},
      properties: {},
    };

    function whitelistedAttrs(node) {
      let returnedAttrs = {};
      for (let attr of node.attributes) {
        if (WHITELISTED_ATTRS.has(attr.name)) {
          returnedAttrs[attr.name] = attr.value;
        }
      }
      return returnedAttrs;
    }
    Object.assign(virtualNodeBase.attributes, whitelistedAttrs(node), {
      style: this.getStyles(node),
    });

    // Resolve to absolute path for image src.
    // Note this doesn't handle srcset
    if (node.src) {
      virtualNodeBase.attributes.src = node.src;
    }

    // XXX get a proper list of properties.
    if (node.value !== undefined) {
      virtualNodeBase.properties.value = node.value;
    }
    if (node.checked !== undefined) {
      virtualNodeBase.properties.checked = node.checked;
    }
    if (node.disabled !== undefined) {
      virtualNodeBase.properties.disabled = node.disabled;
    }

    return virtualNodeBase;
  }

  createVirtualNode(node) {
    let { $nodesToVirtualNodes } = this;
    let isDocElement = node == this.doc.documentElement;
    const parentTree = $nodesToVirtualNodes.get(node.parentNode);
    if ((!parentTree || parentTree.IGNORE_CHILDREN) && !isDocElement) {
      return;
    }
    // XXX Handle ::after/::before with CSS.
    if (node.isNativeAnonymous) {
      return;
    }
    if (
      node.tagName == "HEAD" ||
      node.tagName == "SCRIPT" ||
      node.tagName == "LINK" ||
      node.tagName == "STYLE"
    ) {
      // XXX: Should any of this come across?
      return;
    }
    if (node.nodeType == 3) {
      let virtualNode = {
        id: ExtensionUtils.getUniqueId(),
        parentID: parentTree.id,
        nodeType: node.nodeType,
        data: node.data,
      };
      this.registerNode(node, virtualNode);
      parentTree.children.push(virtualNode);
    }
    if (!node.tagName) {
      // XXX: why does this happen?
      return;
    }

    if (node.tagName == "IFRAME" || node.tagName == "VIDEO") {
      // Put a placeholder to avoid messing up UA styles like
      // `body > h1:-moz-first-node` with markup like `<body><style><h1>`
      let virtualNode = {
        children: [],
        id: ExtensionUtils.getUniqueId(),
        parentID: parentTree.id,
        originalTag: node.tagName.toLowerCase(),
        IGNORE_CHILDREN: true,
        tag: "div",
        attributes: {},
      };

      // XXX: move the parentTree.children positioning into registerNode
      this.registerNode(node, virtualNode);
      parentTree.children.push(virtualNode);
    } else {
      let virtualNode = this.getVirtualNodeBase(node);
      Object.assign(virtualNode, {
        id: ExtensionUtils.getUniqueId(),
        parentID: isDocElement ? null : parentTree.id,
        children: [],
      });
      this.registerNode(node, virtualNode);
      if (!isDocElement) {
        parentTree.children.push(virtualNode);
      }
    }
  }

  createWalker(rootNode) {
    let walker = Cc["@mozilla.org/inspector/deep-tree-walker;1"].createInstance(
      Ci.inIDeepTreeWalker
    );
    walker.showAnonymousContent = true;
    walker.showSubDocuments = true;
    walker.showDocumentsAsNodes = true;
    walker.init(
      rootNode,
      nodeFilterConstants.SHOW_TEXT | nodeFilterConstants.SHOW_ELEMENT
    );
    return walker;
  }

  createVirtualNodeAndChildren(node) {
    let { $nodesToVirtualNodes } = this;
    let walker = this.createWalker(node);
    let currentNode = walker.currentNode;
    do {
      if ($nodesToVirtualNodes.has(currentNode)) {
        console.log(
          `Attempting to create a node that already exists (${
            $nodesToVirtualNodes.get(currentNode).id
          })`
        );
      } else {
        this.createVirtualNode(currentNode);
      }
    } while ((currentNode = walker.nextNode()));
  }

  bake() {
    let { $nodesToVirtualNodes } = this;

    let documentElement = this.doc.documentElement;
    this.createVirtualNodeAndChildren(documentElement);
    if (!$nodesToVirtualNodes.has(documentElement)) {
      throw new Error("Missing documentElement, this shouldn't have happened");
    }
    this.startWatching();
    return $nodesToVirtualNodes.get(documentElement);
  }
}

class Network extends ContentProcessDomain {
  // commands

  /**
   * Internal methods: the following methods are not part of CDP;
   * note the _ prefix.
   */

  _updateLoadFlags(flags) {
    this.docShell.defaultLoadFlags = flags;
  }

  get page() {
    return this.session.domains.get("Page");
  }

  getNodeFromRemoteID(remoteID) {
    let DOMState = contentDOMState.get(this.content);
    let node;
    if (DOMState && remoteID) {
      node = DOMState.$idsToNodes.get(parseInt(remoteID));
    }

    return node || null;
  }

  emitToUAServer(message) {
    this.emit("Page.javascriptDialogOpening", {
      type: "beforeunload",
      message,
    });
  }

  agentScroll(options = {}) {
    if (options.target == "document") {
      // XXX: This could end up targeting the wrong window if the
      // client sent an event before the server navigated. I'd prefer
      // if we made a "virtualNode" for the document that can keep metadata
      // like this and would have a target id to make sure we are talking to
      // the right one.
      this.content.scrollTo(options.scrollX, options.scrollY);
    } else {
      let target = this.getNodeFromRemoteID(options.target);
      if (target) {
        target.scrollTo(options.scrollX, options.scrollY);
      }
    }
  }

  agentKey(options = {}) {
    let target = this.getNodeFromRemoteID(options.target);
    let relatedTarget = this.getNodeFromRemoteID(options.relatedTarget);
    if (target) {
      // XXX: This doesn't actually work.
      // See EventUtils.synthesizeKey, perhaps:
      // https://searchfox.org/mozilla-central/rev/9aa7bebfd169bc2ead00ef596498a406e56bbb85/testing/mochitest/tests/SimpleTest/EventUtils.js#1037
      let event = new KeyboardEvent(options.type, {
        bubbles: true,
        cancelable: true,
        view: target.ownerGlobal,
        target,
        relatedTarget,
        ...options,
      });
      target.dispatchEvent(event);
    }
  }

  agentMouse(options = {}) {
    let target = this.getNodeFromRemoteID(options.target);
    let relatedTarget = this.getNodeFromRemoteID(options.relatedTarget);
    if (target) {
      target.dispatchEvent(
        new MouseEvent(options.type, {
          bubbles: true,
          cancelable: true,
          view: target.ownerGlobal,
          target,
          relatedTarget,
          ...options,
        })
      );
    }
  }

  createDOMStateForCurrentWindow() {
    let DOMState = contentDOMState.get(this.content);
    if (!contentDOMState.has(this.content)) {
      DOMState = new DOMBaker(this);
      contentDOMState.set(this.content, DOMState);
    }
    return DOMState;
  }

  doBakedDOM() {
    // Once we want to handle page navigations, see this code:
    this.page.addEventListener((name, params) => {
      // this.chromeEventHandler.removeEventListener("unload", this, {
      //   mozSystemGroup: true,
      //   capture: true,
      // });
      if (name == "Page.domContentEventFired") {
        // XXX or Page.frameNavigated
        let DOMState = this.createDOMStateForCurrentWindow();
        let initialBaked = DOMState.bake();

        this.emitToUAServer({
          overriddenType: "bakedDOM",
          data: initialBaked,
        });
      } else if (name == "Page.frameStartedLoading") {
        // XXX: maybe on this.content.chromeEventHandler "unload" instead?
        let DOMState = contentDOMState.get(this.content);
        if (DOMState) {
          DOMState.stopWatching();
          contentDOMState.delete(this.content);
        }
      }
      // console.log(name, params);
    });
    let DOMState = this.createDOMStateForCurrentWindow();
    return DOMState.bake();
  }
}
