var uiWebview_SearchResultCount = 0;

/*!
 @method     uiWebview_HighlightAllOccurencesOfStringForElement
 @abstract   // helper function, recursively searches in elements and their child nodes
 @discussion // helper function, recursively searches in elements and their child nodes

 element    - HTML elements
 keyword    - string to search
 */

function isElementVisible(e) {
    return true
}

function uiWebview_HighlightAllOccurencesOfStringForElement(element,keyword) {
    if (element) {
        if (element.nodeType == 3) {        // Text node
            var count = 0;
            var elementTmp = element;
            while (true) {
                var value = elementTmp.nodeValue;  // Search for keyword in text node
                var idx = value.toLowerCase().indexOf(keyword);

                if (idx < 0) break;

                count++;
                elementTmp = document.createTextNode(value.substr(idx+keyword.length));
            }

            uiWebview_SearchResultCount += count;

            var index = uiWebview_SearchResultCount;
            while (true) {
                var value = element.nodeValue;  // Search for keyword in text node
                var idx = value.toLowerCase().indexOf(keyword);

                if (idx < 0) break;             // not found, abort

                var span = document.createElement("span");
                var text = document.createTextNode(value.substr(idx,keyword.length));
                span.appendChild(text);

                span.setAttribute("class","uiWebviewHighlight");
                span.style.position = "relative";
                span.style.display = "inline-block";
                span.style.backgroundColor="#ffe438";
                span.style.color="black";
                span.style.borderRadius="3px";
                span.style.scrollMargin="44px";
                span.style.zIndex = "1001"; // Ensure highlights are above the overlay

                index--;
                span.setAttribute("id", "SEARCH WORD"+(index));
                
                var beforeStyle = document.createElement('style');
                beforeStyle.innerHTML = `
                             .uiWebviewHighlight::before {
                                 content: '';
                                 position: absolute;
                                 top: 0px;
                                 bottom: 0px;
                                 left: -2px;
                                 right: -2px;
                                 background-color: #ffe438;
                                 z-index: -1;
                                 border-radius: 3px;
                             }
                             .dark-overlay {
                                 position: fixed;
                                 top: 0;
                                 left: 0;
                                 width: 100%;
                                 height: 100%;
                                 background-color: rgba(0, 0, 0, 0.22);
                                 z-index: 1000;
                                 pointer-events: none;
                             }
                         `;
                document.head.appendChild(beforeStyle);

                text = document.createTextNode(value.substr(idx+keyword.length));
                element.deleteData(idx, value.length - idx);

                var next = element.nextSibling;
                element.parentNode.insertBefore(span, next);
                element.parentNode.insertBefore(text, next);
                element = text;
            }


        } else if (element.nodeType == 1) { // Element node
            if (element.nodeName.toLowerCase() != 'select' && isElementVisible(element)) {
                for (var i=element.childNodes.length-1; i>=0; i--) {
                    uiWebview_HighlightAllOccurencesOfStringForElement(element.childNodes[i],keyword);
                }
            }
        }
    }
}

// the main entry point to start the search
function uiWebview_HighlightAllOccurencesOfString(keyword) {
    uiWebview_RemoveAllHighlights();
    uiWebview_AddDarkOverlay();
    uiWebview_HighlightAllOccurencesOfStringForElement(document.body, keyword.toLowerCase());
}

// helper function, recursively removes the highlights in elements and their childs
function uiWebview_RemoveAllHighlightsForElement(element) {
    if (element) {
        if (element.nodeType == 1) {
            if (element.getAttribute("class") == "uiWebviewHighlight") {
                var text = element.removeChild(element.firstChild);
                element.parentNode.insertBefore(text,element);
                element.parentNode.removeChild(element);
                return true;
            } else {
                var normalize = false;
                for (var i=element.childNodes.length-1; i>=0; i--) {
                    if (uiWebview_RemoveAllHighlightsForElement(element.childNodes[i])) {
                        normalize = true;
                    }
                }
                if (normalize) {
                    element.normalize();
                }
            }
        }
    }
    return false;
}

// the main entry point to remove the highlights
function uiWebview_RemoveAllHighlights() {
    uiWebview_SearchResultCount = 0;
    uiWebview_RemoveAllHighlightsForElement(document.body);
    uiWebview_RemoveDarkOverlay();
}

function uiWebview_ScrollTo(idx) {
    var scrollTo = document.getElementById("SEARCH WORD" + idx);
    if (scrollTo) scrollTo.scrollIntoView();
}

function uiWebview_AddDarkOverlay() {
    var overlay = document.createElement('div');
    overlay.classList.add('dark-overlay');
    overlay.setAttribute('id', 'dark-overlay');
    document.body.appendChild(overlay);
}

function uiWebview_RemoveDarkOverlay() {
    var overlay = document.getElementById('dark-overlay');
    if (overlay) {
        document.body.removeChild(overlay);
    }
}
