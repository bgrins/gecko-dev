/* -*- Mode: Objective-C++; tab-width: 2; indent-tabs-mode: nil; c-basic-offset: 2 -*- */
/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

#import "mozAccessible.h"

#import "MacUtils.h"
#import "mozView.h"

#include "Accessible-inl.h"
#include "nsAccUtils.h"
#include "nsIPersistentProperties2.h"
#include "DocAccessibleParent.h"
#include "Relation.h"
#include "Role.h"
#include "RootAccessible.h"
#include "TableAccessible.h"
#include "TableCellAccessible.h"
#include "mozilla/a11y/PDocAccessible.h"
#include "mozilla/dom/BrowserParent.h"
#include "OuterDocAccessible.h"
#include "nsChildView.h"

#include "nsRect.h"
#include "nsCocoaUtils.h"
#include "nsCoord.h"
#include "nsObjCExceptions.h"
#include "nsWhitespaceTokenizer.h"
#include <prdtoa.h>

using namespace mozilla;
using namespace mozilla::a11y;

#define NSAccessibilityRequiredAttribute @"AXRequired"
#define NSAccessibilityARIACurrentAttribute @"AXARIACurrent"
#define NSAccessibilityDOMIdentifierAttribute @"AXDOMIdentifier"
#define NSAccessibilityHasPopupAttribute @"AXHasPopup"
#define NSAccessibilityPopupValueAttribute @"AXPopupValue"
#define NSAccessibilityMathRootRadicandAttribute @"AXMathRootRadicand"
#define NSAccessibilityMathRootIndexAttribute @"AXMathRootIndex"
#define NSAccessibilityMathFractionNumeratorAttribute @"AXMathFractionNumerator"
#define NSAccessibilityMathFractionDenominatorAttribute @"AXMathFractionDenominator"
#define NSAccessibilityMathBaseAttribute @"AXMathBase"
#define NSAccessibilityMathSubscriptAttribute @"AXMathSubscript"
#define NSAccessibilityMathSuperscriptAttribute @"AXMathSuperscript"
#define NSAccessibilityMathUnderAttribute @"AXMathUnder"
#define NSAccessibilityMathOverAttribute @"AXMathOver"
#define NSAccessibilityMathLineThicknessAttribute @"AXMathLineThickness"
#define NSAccessibilityScrollToVisibleAction @"AXScrollToVisible"

// XXX WebKit also defines the following attributes.
// See bugs 1176970 and 1176983.
// - NSAccessibilityMathFencedOpenAttribute @"AXMathFencedOpen"
// - NSAccessibilityMathFencedCloseAttribute @"AXMathFencedClose"
// - NSAccessibilityMathPrescriptsAttribute @"AXMathPrescripts"
// - NSAccessibilityMathPostscriptsAttribute @"AXMathPostscripts"

#pragma mark -

@implementation mozAccessible

- (id)initWithAccessible:(AccessibleOrProxy)aAccOrProxy {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;
  MOZ_ASSERT(!aAccOrProxy.IsNull(), "Cannot init mozAccessible with null");
  if ((self = [super init])) {
    mGeckoAccessible = aAccOrProxy;
    mRole = aAccOrProxy.Role();
  }

  return self;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (void)dealloc {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  [super dealloc];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

#pragma mark -

- (BOOL)isAccessibilityElement {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  if ([self isExpired]) {
    return ![self ignoreWithParent:nil];
  }

  mozAccessible* parent = nil;
  AccessibleOrProxy p = mGeckoAccessible.Parent();

  if (!p.IsNull()) {
    parent = GetNativeFromGeckoAccessible(p);
  }

  return ![self ignoreWithParent:parent];

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NO);
}

- (BOOL)ignoreWithParent:(mozAccessible*)parent {
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    if (acc->IsContent() && acc->GetContent()->IsXULElement()) {
      if (acc->VisibilityState() & states::INVISIBLE) {
        return YES;
      }
    }
  }

  return [parent ignoreChild:self];
}

- (BOOL)ignoreChild:(mozAccessible*)child {
  return NO;
}

- (NSArray*)additionalAccessibilityAttributeNames {
  NSMutableArray* additional = [NSMutableArray array];
  [additional addObject:NSAccessibilityDOMIdentifierAttribute];
  switch (mRole) {
    case roles::SUMMARY:
      [additional addObject:NSAccessibilityExpandedAttribute];
      break;
    case roles::MATHML_ROOT:
      [additional addObject:NSAccessibilityMathRootIndexAttribute];
      [additional addObject:NSAccessibilityMathRootRadicandAttribute];
      break;
    case roles::MATHML_SQUARE_ROOT:
      [additional addObject:NSAccessibilityMathRootRadicandAttribute];
      break;
    case roles::MATHML_FRACTION:
      [additional addObject:NSAccessibilityMathFractionNumeratorAttribute];
      [additional addObject:NSAccessibilityMathFractionDenominatorAttribute];
      [additional addObject:NSAccessibilityMathLineThicknessAttribute];
      break;
    case roles::MATHML_SUB:
    case roles::MATHML_SUP:
    case roles::MATHML_SUB_SUP:
      [additional addObject:NSAccessibilityMathBaseAttribute];
      [additional addObject:NSAccessibilityMathSubscriptAttribute];
      [additional addObject:NSAccessibilityMathSuperscriptAttribute];
      break;
    case roles::MATHML_UNDER:
    case roles::MATHML_OVER:
    case roles::MATHML_UNDER_OVER:
      [additional addObject:NSAccessibilityMathBaseAttribute];
      [additional addObject:NSAccessibilityMathUnderAttribute];
      [additional addObject:NSAccessibilityMathOverAttribute];
      break;
    // XXX bug 1176983
    // roles::MATHML_MULTISCRIPTS should also have the following attributes:
    // - NSAccessibilityMathPrescriptsAttribute
    // - NSAccessibilityMathPostscriptsAttribute
    // XXX bug 1176970
    // roles::MATHML_FENCED should also have the following attributes:
    // - NSAccessibilityMathFencedOpenAttribute
    // - NSAccessibilityMathFencedCloseAttribute
    default:
      break;
  }

  return additional;
}

- (NSArray*)accessibilityAttributeNames {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  // if we're expired, we don't support any attributes.
  if ([self isExpired]) {
    return [NSArray array];
  }

  static NSArray* generalAttributes = nil;

  if (!generalAttributes) {
    // standard attributes that are shared and supported by all generic elements.
    generalAttributes = [[NSArray alloc]
        initWithObjects:NSAccessibilityChildrenAttribute, NSAccessibilityParentAttribute,
                        NSAccessibilityRoleAttribute, NSAccessibilityTitleAttribute,
                        NSAccessibilityValueAttribute, NSAccessibilitySubroleAttribute,
                        NSAccessibilityRoleDescriptionAttribute, NSAccessibilityPositionAttribute,
                        NSAccessibilityEnabledAttribute, NSAccessibilitySizeAttribute,
                        NSAccessibilityWindowAttribute, NSAccessibilityFocusedAttribute,
                        NSAccessibilityHelpAttribute, NSAccessibilityTitleUIElementAttribute,
                        NSAccessibilityTopLevelUIElementAttribute, NSAccessibilityHasPopupAttribute,
                        NSAccessibilityARIACurrentAttribute, NSAccessibilitySelectedAttribute,
                        NSAccessibilityRequiredAttribute,
#if DEBUG
                        @"AXMozDescription",
#endif
                        nil];
  }

  NSArray* objectAttributes = generalAttributes;

  NSArray* additionalAttributes = [self additionalAccessibilityAttributeNames];
  if ([additionalAttributes count])
    objectAttributes = [objectAttributes arrayByAddingObjectsFromArray:additionalAttributes];

  return [objectAttributes arrayByAddingObjectsFromArray:[super accessibilityAttributeNames]];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (id)childAt:(uint32_t)i {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  AccessibleOrProxy child = mGeckoAccessible.ChildAt(i);
  return !child.IsNull() ? GetNativeFromGeckoAccessible(child) : nil;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

static const uint64_t kCachedStates = states::CHECKED | states::PRESSED | states::MIXED |
                                      states::EXPANDED | states::CURRENT | states::SELECTED |
                                      states::TRAVERSED | states::LINKED | states::HASPOPUP;
static const uint64_t kCacheInitialized = ((uint64_t)0x1) << 63;

- (uint64_t)state {
  uint64_t state = 0;

  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    state = acc->State();
  }

  if (ProxyAccessible* proxy = mGeckoAccessible.AsProxy()) {
    state = proxy->State();
  }

  if (!(mCachedState & kCacheInitialized)) {
    mCachedState = state & kCachedStates;
    mCachedState |= kCacheInitialized;
  }

  return state;
}

- (uint64_t)stateWithMask:(uint64_t)mask {
  if ((mask & kCachedStates) == mask && (mCachedState & kCacheInitialized) != 0) {
    return mCachedState & mask;
  }

  return [self state] & mask;
}

- (void)stateChanged:(uint64_t)state isEnabled:(BOOL)enabled {
  if ((state & kCachedStates) == 0) {
    return;
  }

  if (!(mCachedState & kCacheInitialized)) {
    [self state];
    return;
  }

  if (enabled) {
    mCachedState |= state;
  } else {
    mCachedState &= ~state;
  }
}

- (void)invalidateState {
  mCachedState = 0;
}

- (id)accessibilityAttributeValue:(NSString*)attribute {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  if ([self isExpired]) {
    return nil;
  }

  Accessible* acc = mGeckoAccessible.AsAccessible();
  ProxyAccessible* proxy = mGeckoAccessible.AsProxy();

#if DEBUG
  if ([attribute isEqualToString:@"AXMozDescription"])
    return [NSString stringWithFormat:@"role = %u native = %@", mRole, [self class]];
#endif

  if ([attribute isEqualToString:NSAccessibilityChildrenAttribute]) return [self children];
  if ([attribute isEqualToString:NSAccessibilityExpandedAttribute]) {
    return [NSNumber numberWithBool:[self stateWithMask:states::EXPANDED] != 0];
  }
  if ([attribute isEqualToString:NSAccessibilityParentAttribute]) return [self parent];

#ifdef DEBUG_hakan
  NSLog(@"(%@ responding to attr %@)", self, attribute);
#endif

  if ([attribute isEqualToString:NSAccessibilityRoleAttribute]) return [self role];
  if ([attribute isEqualToString:NSAccessibilityPositionAttribute]) return [self position];
  if ([attribute isEqualToString:NSAccessibilitySubroleAttribute]) return [self subrole];
  if ([attribute isEqualToString:NSAccessibilityEnabledAttribute])
    return [NSNumber numberWithBool:[self isEnabled]];
  if ([attribute isEqualToString:NSAccessibilityHasPopupAttribute]) {
    if ([self stateWithMask:states::HASPOPUP] != 0) {
      return utils::GetAccAttr(self, "haspopup");
    } else {
      return nil;
    }
  }
  if ([attribute isEqualToString:NSAccessibilityValueAttribute]) return [self value];
  if ([attribute isEqualToString:NSAccessibilityARIACurrentAttribute]) {
    if ([self stateWithMask:states::CURRENT]) {
      return utils::GetAccAttr(self, "current");
    } else {
      return nil;
    }
  }
  if ([attribute isEqualToString:NSAccessibilitySelectedAttribute]) {
    return [NSNumber numberWithBool:NO];
  }
  if ([attribute isEqualToString:NSAccessibilityRoleDescriptionAttribute])
    return [self roleDescription];
  if ([attribute isEqualToString:NSAccessibilityFocusedAttribute])
    return [NSNumber numberWithBool:[self isFocused]];
  if ([attribute isEqualToString:NSAccessibilitySizeAttribute]) return [self size];
  if ([attribute isEqualToString:NSAccessibilityWindowAttribute]) return [self window];
  if ([attribute isEqualToString:NSAccessibilityTopLevelUIElementAttribute]) return [self window];
  if ([attribute isEqualToString:NSAccessibilityTitleAttribute]) return [self title];
  if ([attribute isEqualToString:NSAccessibilityTitleUIElementAttribute]) {
    /* If our accessible is labelled by more than one item, its label
     * should be set by accessibilityLabel instead of here, so we return nil.
     */
    if (acc) {
      Relation rel = acc->RelationByType(RelationType::LABELLED_BY);
      Accessible* tempAcc = rel.Next();
      if (tempAcc && !rel.Next()) {
        mozAccessible* label = GetNativeFromGeckoAccessible(tempAcc);
        return [label isAccessibilityElement] ? label : nil;
      } else {
        return nil;
      }
    }
    nsTArray<ProxyAccessible*> rel = proxy->RelationByType(RelationType::LABELLED_BY);
    ProxyAccessible* tempProxy = rel.SafeElementAt(0);
    if (tempProxy && rel.Length() <= 1) {
      mozAccessible* label = GetNativeFromGeckoAccessible(tempProxy);
      return [label isAccessibilityElement] ? label : nil;
    } else {
      return nil;
    }
  }
  if ([attribute isEqualToString:NSAccessibilityHelpAttribute]) return [self help];
  if ([attribute isEqualToString:NSAccessibilityOrientationAttribute]) return [self orientation];

  if ([attribute isEqualToString:NSAccessibilityDOMIdentifierAttribute]) {
    nsAutoString id;
    if (acc && acc->GetContent())
      nsCoreUtils::GetID(acc->GetContent(), id);
    else
      proxy->DOMNodeID(id);
    return nsCocoaUtils::ToNSString(id);
  }

  if ([attribute isEqualToString:NSAccessibilityRequiredAttribute]) {
    return [NSNumber numberWithBool:[self stateWithMask:states::REQUIRED] != 0];
  }

  switch (mRole) {
    case roles::MATHML_ROOT:
      if ([attribute isEqualToString:NSAccessibilityMathRootRadicandAttribute])
        return [self childAt:0];
      if ([attribute isEqualToString:NSAccessibilityMathRootIndexAttribute])
        return [self childAt:1];
      break;
    case roles::MATHML_SQUARE_ROOT:
      if ([attribute isEqualToString:NSAccessibilityMathRootRadicandAttribute])
        return [self childAt:0];
      break;
    case roles::MATHML_FRACTION:
      if ([attribute isEqualToString:NSAccessibilityMathFractionNumeratorAttribute])
        return [self childAt:0];
      if ([attribute isEqualToString:NSAccessibilityMathFractionDenominatorAttribute])
        return [self childAt:1];
      if ([attribute isEqualToString:NSAccessibilityMathLineThicknessAttribute]) {
        // WebKit sets line thickness to some logical value parsed in the
        // renderer object of the <mfrac> element. It's not clear whether the
        // exact value is relevant to assistive technologies. From a semantic
        // point of view, the only important point is to distinguish between
        // <mfrac> elements that have a fraction bar and those that do not.
        // Per the MathML 3 spec, the latter happens iff the linethickness
        // attribute is of the form [zero-float][optional-unit]. In that case we
        // set line thickness to zero and in the other cases we set it to one.
        if (NSString* thickness = utils::GetAccAttr(self, "thickness")) {
          NSNumberFormatter* formatter = [[[NSNumberFormatter alloc] init] autorelease];
          NSNumber* value = [formatter numberFromString:thickness];
          return [NSNumber numberWithBool:[value boolValue]];
        } else {
          return [NSNumber numberWithInteger:0];
        }
      }
      break;
    case roles::MATHML_SUB:
      if ([attribute isEqualToString:NSAccessibilityMathBaseAttribute]) return [self childAt:0];
      if ([attribute isEqualToString:NSAccessibilityMathSubscriptAttribute])
        return [self childAt:1];
#ifdef DEBUG
      if ([attribute isEqualToString:NSAccessibilityMathSuperscriptAttribute]) return nil;
#endif
      break;
    case roles::MATHML_SUP:
      if ([attribute isEqualToString:NSAccessibilityMathBaseAttribute]) return [self childAt:0];
#ifdef DEBUG
      if ([attribute isEqualToString:NSAccessibilityMathSubscriptAttribute]) return nil;
#endif
      if ([attribute isEqualToString:NSAccessibilityMathSuperscriptAttribute])
        return [self childAt:1];
      break;
    case roles::MATHML_SUB_SUP:
      if ([attribute isEqualToString:NSAccessibilityMathBaseAttribute]) return [self childAt:0];
      if ([attribute isEqualToString:NSAccessibilityMathSubscriptAttribute])
        return [self childAt:1];
      if ([attribute isEqualToString:NSAccessibilityMathSuperscriptAttribute])
        return [self childAt:2];
      break;
    case roles::MATHML_UNDER:
      if ([attribute isEqualToString:NSAccessibilityMathBaseAttribute]) return [self childAt:0];
      if ([attribute isEqualToString:NSAccessibilityMathUnderAttribute]) return [self childAt:1];
#ifdef DEBUG
      if ([attribute isEqualToString:NSAccessibilityMathOverAttribute]) return nil;
#endif
      break;
    case roles::MATHML_OVER:
      if ([attribute isEqualToString:NSAccessibilityMathBaseAttribute]) return [self childAt:0];
#ifdef DEBUG
      if ([attribute isEqualToString:NSAccessibilityMathUnderAttribute]) return nil;
#endif
      if ([attribute isEqualToString:NSAccessibilityMathOverAttribute]) return [self childAt:1];
      break;
    case roles::MATHML_UNDER_OVER:
      if ([attribute isEqualToString:NSAccessibilityMathBaseAttribute]) return [self childAt:0];
      if ([attribute isEqualToString:NSAccessibilityMathUnderAttribute]) return [self childAt:1];
      if ([attribute isEqualToString:NSAccessibilityMathOverAttribute]) return [self childAt:2];
      break;
    // XXX bug 1176983
    // roles::MATHML_MULTISCRIPTS should also have the following attributes:
    // - NSAccessibilityMathPrescriptsAttribute
    // - NSAccessibilityMathPostscriptsAttribute
    // XXX bug 1176970
    // roles::MATHML_FENCED should also have the following attributes:
    // - NSAccessibilityMathFencedOpenAttribute
    // - NSAccessibilityMathFencedCloseAttribute
    default:
      break;
  }

  return [super accessibilityAttributeValue:attribute];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (BOOL)accessibilityIsAttributeSettable:(NSString*)attribute {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_RETURN;

  if ([attribute isEqualToString:NSAccessibilityFocusedAttribute]) return [self canBeFocused];

  return [super accessibilityIsAttributeSettable:attribute];

  NS_OBJC_END_TRY_ABORT_BLOCK_RETURN(NO);
}

- (void)accessibilitySetValue:(id)value forAttribute:(NSString*)attribute {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

#ifdef DEBUG_hakan
  NSLog(@"[%@] %@='%@'", self, attribute, value);
#endif

  // we only support focusing elements so far.
  if ([attribute isEqualToString:NSAccessibilityFocusedAttribute] && [value boolValue]) {
    [self focus];
  } else {
    [super accessibilitySetValue:value forAttribute:attribute];
  }

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (id)moxHitTest:(NSPoint)point {
  // Convert the given screen-global point in the cocoa coordinate system (with
  // origin in the bottom-left corner of the screen) into point in the Gecko
  // coordinate system (with origin in a top-left screen point).
  NSScreen* mainView = [[NSScreen screens] objectAtIndex:0];
  NSPoint tmpPoint = NSMakePoint(point.x, [mainView frame].size.height - point.y);
  LayoutDeviceIntPoint geckoPoint =
      nsCocoaUtils::CocoaPointsToDevPixels(tmpPoint, nsCocoaUtils::GetBackingScaleFactor(mainView));

  AccessibleOrProxy child =
      mGeckoAccessible.ChildAtPoint(geckoPoint.x, geckoPoint.y, Accessible::eDeepestChild);

  if (!child.IsNull()) {
    mozAccessible* nativeChild = GetNativeFromGeckoAccessible(child);
    return [nativeChild isAccessibilityElement] ? nativeChild : [nativeChild parent];
  }

  // if we didn't find anything, return ourself or child view.
  return self;
}

- (NSArray*)accessibilityActionNames {
  if ([self isExpired]) {
    return @[];
  }

  Accessible* acc = mGeckoAccessible.AsAccessible();
  ProxyAccessible* proxy = mGeckoAccessible.AsProxy();
  // Create actions array
  NSMutableArray* actions = [NSMutableArray new];

  uint8_t count = 0;
  if (acc) {
    count = acc->ActionCount();
  } else if (proxy) {
    count = proxy->ActionCount();
  }

  // Check if the accessible has an existing gecko
  // action, and add the corresponding Mac action to
  // the actions array. `count` is guaranteed to be 0 or 1
  // If an action exists, add a "AXPress" action
  // to our native object.
  if (count) {
    [actions addObject:NSAccessibilityPressAction];
  }

  // Regardless of `count`, add actions that should be
  // performable on all accessibles. If we added a press
  // action, it will be first in the list. We append other
  // actions here to maintain that invariant.
  [actions addObject:NSAccessibilityScrollToVisibleAction];
  [actions addObject:NSAccessibilityShowMenuAction];

  return [actions arrayByAddingObjectsFromArray:[super accessibilityActionNames]];
}

- (BOOL)providesLabelNotTitle {
  // These accessible types are the exception to the rule of label vs. title:
  // They may be named explicitly, but they still provide a label not a title.
  return mRole == roles::GROUPING || mRole == roles::RADIO_GROUP || mRole == roles::FIGURE ||
         mRole == roles::GRAPHIC;
}

- (NSString*)accessibilityLabel {
  if ([self isExpired]) {
    return nil;
  }

  Accessible* acc = mGeckoAccessible.AsAccessible();
  ProxyAccessible* proxy = mGeckoAccessible.AsProxy();
  nsAutoString name;

  /* If our accessible is:
   * 1. Named by invisible text, or
   * 2. Has more than one labeling relation, or
   * 3. Is a special role defined in providesLabelNotTitle
   *   ... return its name as a label (AXDescription).
   */
  if (acc) {
    ENameValueFlag flag = acc->Name(name);
    if (flag == eNameFromSubtree) {
      return nil;
    }

    if (![self providesLabelNotTitle]) {
      Relation rel = acc->RelationByType(RelationType::LABELLED_BY);
      if (rel.Next() && !rel.Next()) {
        return nil;
      }
    }
  } else if (proxy) {
    uint32_t flag = proxy->Name(name);
    if (flag == eNameFromSubtree) {
      return nil;
    }

    if (![self providesLabelNotTitle]) {
      nsTArray<ProxyAccessible*> rels = proxy->RelationByType(RelationType::LABELLED_BY);
      if (rels.Length() == 1) {
        return nil;
      }
    }
  }

  return nsCocoaUtils::ToNSString(name);
}

- (void)accessibilityPerformAction:(NSString*)action {
  if ([self isExpired]) {
    return;
  }

  RefPtr<AccessibleWrap> acc = reinterpret_cast<AccessibleWrap*>(mGeckoAccessible.AsAccessible());
  ProxyAccessible* proxy = mGeckoAccessible.AsProxy();

  if ([action isEqualToString:NSAccessibilityScrollToVisibleAction]) {
    if (acc) {
      acc->ScrollTo(nsIAccessibleScrollType::SCROLL_TYPE_ANYWHERE);
    } else if (proxy) {
      proxy->ScrollTo(nsIAccessibleScrollType::SCROLL_TYPE_ANYWHERE);
    }
  } else if ([action isEqualToString:NSAccessibilityShowMenuAction]) {
    // We don't need to convert this rect into mac coordinates because the
    // mouse event synthesizer expects layout (gecko) coordinates.
    LayoutDeviceIntRect geckoRect;
    id objOrView = nil;
    if (acc) {
      geckoRect = LayoutDeviceIntRect::FromUnknownRect(acc->Bounds());
      objOrView = GetObjectOrRepresentedView(GetNativeFromGeckoAccessible(acc->RootAccessible()));
    } else if (proxy) {
      geckoRect = LayoutDeviceIntRect::FromUnknownRect(proxy->Bounds());
      objOrView = GetObjectOrRepresentedView(
          GetNativeFromGeckoAccessible(proxy->OuterDocOfRemoteBrowser()->RootAccessible()));
    }

    LayoutDeviceIntPoint p = LayoutDeviceIntPoint(geckoRect.X() + (geckoRect.Width() / 2),
                                                  geckoRect.Y() + (geckoRect.Height() / 2));
    nsIWidget* widget = [objOrView widget];
    // XXX: NSRightMouseDown is depreciated in 10.12, should be
    // changed to NSEventTypeRightMouseDown after refactoring.
    widget->SynthesizeNativeMouseEvent(p, NSRightMouseDown, 0, nullptr);

  } else if ([action isEqualToString:NSAccessibilityPressAction]) {
    if (acc) {
      acc->DoAction(0);
    } else if (proxy) {
      proxy->DoAction(0);
    }
    // Activating accessible may alter its state.
    [self invalidateState];
  } else {
    [super accessibilityPerformAction:action];
  }
}

- (id)moxFocusedUIElement {
  if ([self isExpired]) {
    return nil;
  }

  Accessible* acc = mGeckoAccessible.AsAccessible();
  ProxyAccessible* proxy = mGeckoAccessible.AsProxy();

  mozAccessible* focusedChild = nil;
  if (acc) {
    Accessible* focusedGeckoChild = acc->FocusedChild();
    if (focusedGeckoChild) {
      focusedChild = GetNativeFromGeckoAccessible(focusedGeckoChild);
    } else {
      dom::BrowserParent* browser = dom::BrowserParent::GetFocused();
      if (browser) {
        a11y::DocAccessibleParent* proxyDoc = browser->GetTopLevelDocAccessible();
        if (proxyDoc) {
          mozAccessible* nativeRemoteChild = GetNativeFromGeckoAccessible(proxyDoc);
          return [nativeRemoteChild accessibilityFocusedUIElement];
        }
      }
    }
  } else if (proxy) {
    ProxyAccessible* focusedGeckoChild = proxy->FocusedChild();
    if (focusedGeckoChild) {
      focusedChild = GetNativeFromGeckoAccessible(focusedGeckoChild);
    }
  }

  if ([focusedChild isAccessibilityElement]) {
    return focusedChild;
  }

  // return ourself if we can't get a native focused child.
  return self;
}

#pragma mark -

- (mozilla::a11y::AccessibleOrProxy)geckoAccessible {
  return mGeckoAccessible;
}

- (id<mozAccessible>)parent {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;
  if ([self isExpired]) {
    return nil;
  }

  AccessibleOrProxy parent = mGeckoAccessible.Parent();

  if (parent.IsNull()) {
    return nil;
  }

  id nativeParent = GetNativeFromGeckoAccessible(parent);
  if (!nativeParent && mGeckoAccessible.IsAccessible()) {
    // Return native of root accessible if we have no direct parent.
    // XXX: need to return a sensible fallback in proxy case as well
    nativeParent = GetNativeFromGeckoAccessible(mGeckoAccessible.AsAccessible()->RootAccessible());
  }

  if (![nativeParent isAccessibilityElement]) {
    nativeParent = [nativeParent parent];
  }

  return GetObjectOrRepresentedView(nativeParent);

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (BOOL)hasRepresentedView {
  return NO;
}

- (id)representedView {
  return nil;
}

- (BOOL)isRoot {
  return NO;
}

// gets our native children lazily.
- (NSArray*)children {
  NSMutableArray* children =
      [[NSMutableArray alloc] initWithCapacity:mGeckoAccessible.ChildCount()];

  for (uint32_t childIdx = 0; childIdx < mGeckoAccessible.ChildCount(); childIdx++) {
    AccessibleOrProxy child = mGeckoAccessible.ChildAt(childIdx);
    mozAccessible* nativeChild = GetNativeFromGeckoAccessible(child);
    if (!nativeChild) {
      continue;
    }

    if ([nativeChild ignoreWithParent:self]) {
      // If this child should be ignored get its unignored children.
      // This will in turn recurse to any unignored descendants if the
      // child is ignored.
      [children addObjectsFromArray:[nativeChild children]];
    } else {
      [children addObject:nativeChild];
    }
  }

  return children;
}

- (NSValue*)position {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  nsIntRect rect;
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    rect = acc->Bounds();
  } else if (ProxyAccessible* proxy = mGeckoAccessible.AsProxy()) {
    rect = proxy->Bounds();
  } else {
    return nil;
  }

  NSScreen* mainView = [[NSScreen screens] objectAtIndex:0];
  CGFloat scaleFactor = nsCocoaUtils::GetBackingScaleFactor(mainView);
  NSPoint p = NSMakePoint(
      static_cast<CGFloat>(rect.x) / scaleFactor,
      [mainView frame].size.height - static_cast<CGFloat>(rect.y + rect.height) / scaleFactor);

  return [NSValue valueWithPoint:p];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (NSValue*)size {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  nsIntRect rect;
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    rect = acc->Bounds();
  } else if (ProxyAccessible* proxy = mGeckoAccessible.AsProxy()) {
    rect = proxy->Bounds();
  } else {
    return nil;
  }

  CGFloat scaleFactor = nsCocoaUtils::GetBackingScaleFactor([[NSScreen screens] objectAtIndex:0]);
  return [NSValue valueWithSize:NSMakeSize(static_cast<CGFloat>(rect.width) / scaleFactor,
                                           static_cast<CGFloat>(rect.height) / scaleFactor)];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (NSString*)role {
#define ROLE(geckoRole, stringRole, atkRole, macRole, msaaRole, ia2Role, androidClass, nameRule) \
  case roles::geckoRole:                                                                         \
    return macRole;

  switch (mRole) {
#include "RoleMap.h"
    default:
      MOZ_ASSERT_UNREACHABLE("Unknown role.");
      return NSAccessibilityUnknownRole;
  }

#undef ROLE
}

- (NSString*)subrole {
  Accessible* acc = mGeckoAccessible.AsAccessible();
  ProxyAccessible* proxy = mGeckoAccessible.AsProxy();

  // Deal with landmarks first
  // macOS groups the specific landmark types of DPub ARIA into two broad
  // categories with corresponding subroles: Navigation and region/container.
  if (mRole == roles::NAVIGATION) return @"AXLandmarkNavigation";
  if (mRole == roles::LANDMARK) {
    nsAtom* landmark = acc ? acc->LandmarkRole() : proxy->LandmarkRole();
    // HTML Elements treated as landmarks, and ARIA landmarks.
    if (landmark) {
      if (landmark == nsGkAtoms::banner) return @"AXLandmarkBanner";
      if (landmark == nsGkAtoms::complementary) return @"AXLandmarkComplementary";
      if (landmark == nsGkAtoms::contentinfo) return @"AXLandmarkContentInfo";
      if (landmark == nsGkAtoms::main) return @"AXLandmarkMain";
      if (landmark == nsGkAtoms::navigation) return @"AXLandmarkNavigation";
      if (landmark == nsGkAtoms::search) return @"AXLandmarkSearch";
    }

    // None of the above, so assume DPub ARIA.
    return @"AXLandmarkRegion";
  }

  // Now, deal with widget roles
  nsStaticAtom* roleAtom = nullptr;
  switch (mRole) {
    case roles::LIST:
      return @"AXContentList";  // 10.6+ NSAccessibilityContentListSubrole;

    case roles::DEFINITION_LIST:
      return @"AXDefinitionList";  // 10.6+ NSAccessibilityDefinitionListSubrole;

    case roles::TERM:
      return @"AXTerm";

    case roles::DEFINITION:
      return @"AXDefinition";

    case roles::MATHML_MATH:
      return @"AXDocumentMath";

    case roles::MATHML_FRACTION:
      return @"AXMathFraction";

    case roles::MATHML_FENCED:
      // XXX bug 1176970
      // This should be AXMathFence, but doing so without implementing the
      // whole fence interface seems to make VoiceOver crash, so we present it
      // as a row for now.
      return @"AXMathRow";

    case roles::MATHML_SUB:
    case roles::MATHML_SUP:
    case roles::MATHML_SUB_SUP:
      return @"AXMathSubscriptSuperscript";

    case roles::MATHML_ROW:
    case roles::MATHML_STYLE:
    case roles::MATHML_ERROR:
      return @"AXMathRow";

    case roles::MATHML_UNDER:
    case roles::MATHML_OVER:
    case roles::MATHML_UNDER_OVER:
      return @"AXMathUnderOver";

    case roles::MATHML_SQUARE_ROOT:
      return @"AXMathSquareRoot";

    case roles::MATHML_ROOT:
      return @"AXMathRoot";

    case roles::MATHML_TEXT:
      return @"AXMathText";

    case roles::MATHML_NUMBER:
      return @"AXMathNumber";

    case roles::MATHML_IDENTIFIER:
      return @"AXMathIdentifier";

    case roles::MATHML_TABLE:
      return @"AXMathTable";

    case roles::MATHML_TABLE_ROW:
      return @"AXMathTableRow";

    case roles::MATHML_CELL:
      return @"AXMathTableCell";

    // XXX: NSAccessibility also uses subroles AXMathSeparatorOperator and
    // AXMathFenceOperator. We should use the NS_MATHML_OPERATOR_FENCE and
    // NS_MATHML_OPERATOR_SEPARATOR bits of nsOperatorFlags, but currently they
    // are only available from the MathML layout code. Hence we just fallback
    // to subrole AXMathOperator for now.
    // XXX bug 1175747 WebKit also creates anonymous operators for <mfenced>
    // which have subroles AXMathSeparatorOperator and AXMathFenceOperator.
    case roles::MATHML_OPERATOR:
      return @"AXMathOperator";

    case roles::MATHML_MULTISCRIPTS:
      return @"AXMathMultiscript";

    case roles::SWITCH:
      return @"AXSwitch";

    case roles::ALERT:
      return @"AXApplicationAlert";

    case roles::DIALOG:
      if (acc && acc->HasARIARole()) {
        const nsRoleMapEntry* roleMap = acc->ARIARoleMap();
        roleAtom = roleMap->roleAtom;
      }
      if (proxy) roleAtom = proxy->ARIARoleAtom();
      if (roleAtom) {
        if (roleAtom == nsGkAtoms::alertdialog) return @"AXApplicationAlertDialog";
        if (roleAtom == nsGkAtoms::dialog) return @"AXApplicationDialog";
      }
      break;

    case roles::APPLICATION:
      return @"AXLandmarkApplication";

    case roles::FORM:
      // This only gets exposed as a landmark if the role comes from ARIA.
      if (acc && acc->HasARIARole()) {
        const nsRoleMapEntry* roleMap = acc->ARIARoleMap();
        roleAtom = roleMap->roleAtom;
      }
      if (proxy) roleAtom = proxy->ARIARoleAtom();
      if (roleAtom && roleAtom == nsGkAtoms::form) return @"AXLandmarkForm";
      break;

    case roles::FORM_LANDMARK:
      // This is a form element that got landmark properties via an accessible
      // name.
      return @"AXLandmarkForm";

    case roles::ANIMATION:
      return @"AXApplicationMarquee";

    case roles::FLAT_EQUATION:
      return @"AXDocumentMath";

    case roles::REGION:
      return @"AXLandmarkRegion";

    case roles::STATUSBAR:
      return @"AXApplicationStatus";

    case roles::PROPERTYPAGE:
      return @"AXTabPanel";

    case roles::TOOLTIP:
      return @"AXUserInterfaceTooltip";

    case roles::DETAILS:
      return @"AXDetails";

    case roles::SUMMARY:
      return @"AXSummary";

    case roles::NOTE:
      return @"AXDocumentNote";

    case roles::OUTLINEITEM:
      return @"AXOutlineRow";

    case roles::ARTICLE:
      return @"AXDocumentArticle";

    case roles::NON_NATIVE_DOCUMENT:
      return @"AXDocument";

    case roles::CONTENT_DELETION:
      return @"AXDeleteStyleGroup";

    case roles::CONTENT_INSERTION:
      return @"AXInsertStyleGroup";

    case roles::CODE:
      return @"AXCodeStyleGroup";

    case roles::TOGGLE_BUTTON:
      return @"AXToggle";

    case roles::PAGETAB:
      return @"AXTabButton";

    case roles::SEPARATOR:
      return @"AXContentSeparator";

    default:
      // These are special. They map to roles::NOTHING
      // and are instructed by the ARIA map to use the native host role.
      if (acc && acc->HasARIARole()) {
        const nsRoleMapEntry* roleMap = acc->ARIARoleMap();
        roleAtom = roleMap->roleAtom;
      }
      if (proxy) roleAtom = proxy->ARIARoleAtom();

      if (roleAtom) {
        if (roleAtom == nsGkAtoms::log_) return @"AXApplicationLog";
        if (roleAtom == nsGkAtoms::timer) return @"AXApplicationTimer";
        // macOS added an AXSubrole value to distinguish generic AXGroup objects
        // from those which are AXGroups as a result of an explicit ARIA role,
        // such as the non-landmark, non-listitem text containers in DPub ARIA.
        if (mRole == roles::FOOTNOTE || mRole == roles::SECTION) {
          return @"AXApplicationGroup";
        }
      }
      break;
  }

  return nil;
}

struct RoleDescrMap {
  NSString* role;
  const nsString description;
};

static const RoleDescrMap sRoleDescrMap[] = {
    {@"AXApplicationAlert", NS_LITERAL_STRING("alert")},
    {@"AXApplicationAlertDialog", NS_LITERAL_STRING("alertDialog")},
    {@"AXApplicationDialog", NS_LITERAL_STRING("dialog")},
    {@"AXApplicationLog", NS_LITERAL_STRING("log")},
    {@"AXApplicationMarquee", NS_LITERAL_STRING("marquee")},
    {@"AXApplicationStatus", NS_LITERAL_STRING("status")},
    {@"AXApplicationTimer", NS_LITERAL_STRING("timer")},
    {@"AXContentSeparator", NS_LITERAL_STRING("separator")},
    {@"AXDefinition", NS_LITERAL_STRING("definition")},
    {@"AXDetails", NS_LITERAL_STRING("details")},
    {@"AXDocument", NS_LITERAL_STRING("document")},
    {@"AXDocumentArticle", NS_LITERAL_STRING("article")},
    {@"AXDocumentMath", NS_LITERAL_STRING("math")},
    {@"AXDocumentNote", NS_LITERAL_STRING("note")},
    {@"AXLandmarkApplication", NS_LITERAL_STRING("application")},
    {@"AXLandmarkBanner", NS_LITERAL_STRING("banner")},
    {@"AXLandmarkComplementary", NS_LITERAL_STRING("complementary")},
    {@"AXLandmarkContentInfo", NS_LITERAL_STRING("content")},
    {@"AXLandmarkMain", NS_LITERAL_STRING("main")},
    {@"AXLandmarkNavigation", NS_LITERAL_STRING("navigation")},
    {@"AXLandmarkRegion", NS_LITERAL_STRING("region")},
    {@"AXLandmarkSearch", NS_LITERAL_STRING("search")},
    {@"AXSearchField", NS_LITERAL_STRING("searchTextField")},
    {@"AXSummary", NS_LITERAL_STRING("summary")},
    {@"AXTabPanel", NS_LITERAL_STRING("tabPanel")},
    {@"AXTerm", NS_LITERAL_STRING("term")},
    {@"AXUserInterfaceTooltip", NS_LITERAL_STRING("tooltip")}};

struct RoleDescrComparator {
  const NSString* mRole;
  explicit RoleDescrComparator(const NSString* aRole) : mRole(aRole) {}
  int operator()(const RoleDescrMap& aEntry) const { return [mRole compare:aEntry.role]; }
};

- (NSString*)roleDescription {
  if (mRole == roles::DOCUMENT) return utils::LocalizedString(NS_LITERAL_STRING("htmlContent"));

  if (mRole == roles::FIGURE) return utils::LocalizedString(NS_LITERAL_STRING("figure"));

  if (mRole == roles::HEADING) return utils::LocalizedString(NS_LITERAL_STRING("heading"));

  if (mRole == roles::MARK) {
    return utils::LocalizedString(NS_LITERAL_STRING("highlight"));
  }

  NSString* subrole = [self subrole];

  if (subrole) {
    size_t idx = 0;
    if (BinarySearchIf(sRoleDescrMap, 0, ArrayLength(sRoleDescrMap), RoleDescrComparator(subrole),
                       &idx)) {
      return utils::LocalizedString(sRoleDescrMap[idx].description);
    }
  }

  return NSAccessibilityRoleDescription([self role], subrole);
}

- (NSString*)title {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  // In some special cases we provide the name in the label (AXDescription).
  if ([self providesLabelNotTitle]) {
    return nil;
  }

  nsAutoString title;
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    acc->Name(title);
  } else {
    mGeckoAccessible.AsProxy()->Name(title);
  }

  return nsCocoaUtils::ToNSString(title);

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (id)value {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  nsAutoString value;
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    acc->Value(value);
  } else {
    mGeckoAccessible.AsProxy()->Value(value);
  }

  return nsCocoaUtils::ToNSString(value);

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (NSString*)help {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  // What needs to go here is actually the accDescription of an item.
  // The MSAA acc_help method has nothing to do with this one.
  nsAutoString helpText;
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    acc->Description(helpText);
  } else {
    mGeckoAccessible.AsProxy()->Description(helpText);
  }

  return nsCocoaUtils::ToNSString(helpText);

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (NSString*)orientation {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  uint64_t state = [self stateWithMask:(states::HORIZONTAL | states::VERTICAL)];

  if (state & states::HORIZONTAL) {
    return NSAccessibilityHorizontalOrientationValue;
  }

  if (state & states::VERTICAL) {
    return NSAccessibilityVerticalOrientationValue;
  }

  return NSAccessibilityUnknownOrientationValue;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

// objc-style description (from NSObject); not to be confused with the accessible description above.
- (NSString*)description {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  return [NSString stringWithFormat:@"(%p) %@", self, [self role]];

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (BOOL)isFocused {
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    return FocusMgr()->IsFocused(acc);
  }

  return false;  // XXX: proxy implementation is needed.
}

- (BOOL)canBeFocused {
  return [self stateWithMask:states::FOCUSABLE] != 0;
}

- (BOOL)focus {
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    acc->TakeFocus();
  } else {
    mGeckoAccessible.AsProxy()->TakeFocus();
  }

  return YES;
}

- (BOOL)isEnabled {
  if ([self stateWithMask:states::UNAVAILABLE]) {
    return NO;
  }

  if (![self isRoot]) {
    mozAccessible* parent = (mozAccessible*)[self parent];
    if (![parent isRoot]) {
      return ![parent disableChild:self];
    }
  }

  return YES;
}

- (BOOL)disableChild:(mozAccessible*)child {
  return NO;
}

- (void)handleAccessibleEvent:(uint32_t)eventType {
  switch (eventType) {
    case nsIAccessibleEvent::EVENT_FOCUS:
      [self moxPostNotification:NSAccessibilityFocusedUIElementChangedNotification];
      break;
    case nsIAccessibleEvent::EVENT_DOCUMENT_LOAD_COMPLETE:
      [self moxPostNotification:NSAccessibilityFocusedUIElementChangedNotification];
      [self moxPostNotification:@"AXLoadComplete"];
      [self moxPostNotification:@"AXLayoutComplete"];
      break;
    case nsIAccessibleEvent::EVENT_MENUPOPUP_START:
      [self moxPostNotification:@"AXMenuOpened"];
      break;
    case nsIAccessibleEvent::EVENT_MENUPOPUP_END:
      [self moxPostNotification:@"AXMenuClosed"];
      break;
    case nsIAccessibleEvent::EVENT_SELECTION:
    case nsIAccessibleEvent::EVENT_SELECTION_ADD:
    case nsIAccessibleEvent::EVENT_SELECTION_REMOVE:
    case nsIAccessibleEvent::EVENT_SELECTION_WITHIN:
      [self moxPostNotification:NSAccessibilitySelectedChildrenChangedNotification];
      break;
  }
}

- (NSWindow*)window {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK_NIL;

  // Get a pointer to the native window (NSWindow) we reside in.
  NSWindow* nativeWindow = nil;
  DocAccessible* docAcc = nullptr;
  if (Accessible* acc = mGeckoAccessible.AsAccessible()) {
    docAcc = acc->Document();
  } else {
    ProxyAccessible* proxy = mGeckoAccessible.AsProxy();
    Accessible* outerDoc = proxy->OuterDocOfRemoteBrowser();
    if (outerDoc) docAcc = outerDoc->Document();
  }

  if (docAcc) nativeWindow = static_cast<NSWindow*>(docAcc->GetNativeWindow());

  NSAssert1(nativeWindow, @"Could not get native window for %@", self);
  return nativeWindow;

  NS_OBJC_END_TRY_ABORT_BLOCK_NIL;
}

- (void)expire {
  NS_OBJC_BEGIN_TRY_ABORT_BLOCK;

  [self invalidateState];

  mGeckoAccessible.SetBits(0);

  [self moxPostNotification:NSAccessibilityUIElementDestroyedNotification];

  NS_OBJC_END_TRY_ABORT_BLOCK;
}

- (BOOL)isExpired {
  return !mGeckoAccessible.AsAccessible() && !mGeckoAccessible.AsProxy();
}

@end
