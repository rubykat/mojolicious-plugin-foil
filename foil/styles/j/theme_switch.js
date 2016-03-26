// Style Switcher

// This now uses jquery.
// And uses cookies.js

// ======================================================
var style_cookie_name = "theme" ;
var style_cookie_age = (60 * 60 * 24 * 7); // time in seconds
var style_cookie_path = "/" ;

// ======================================================

function debug (log_txt) {
    if (typeof window.console != 'undefined') {
        console.log(log_txt);
    }
}

var ThemeSwitcher = new Object();

ThemeSwitcher.get_themes_url = function ( )
{
    // get the default stylesheet link
    var dlink = $("#default_theme");
    var m = dlink.attr("href").match(/(.*\/)theme_/);
    var thurl = m[1] + "themes.json";
    return thurl;
}

ThemeSwitcher.init = function (show_form)
{
    if (typeof show_form == 'undefined') {
        show_form = false;
    }
    this.lookup_themes(this.get_themes_url(),show_form);
}

ThemeSwitcher.build_style_links = function ( themes )
{
    // get the default stylesheet link
    var dlink = $("#default_theme");
    var m = dlink.attr("href").match(/(.*\/theme_)/);
    var shref = m[1];
    var i;
    var links = new Array();
    for (i = 0; i < themes.length; i++)
    {
        var th=themes[i];
        var link = '<link rel="alternative stylesheet" type="text/css" title="' + th + '" href="' + shref + th + '.css"/>';
        links.push(link);
    }
    var altlinks = links.join("\n");
    $(document.head).append(altlinks);
}

ThemeSwitcher.build_form = function ( themes, show_form )
{
    debug("ThemeSwitcher.build_form called");
    var buttons = new Array();
    for (i = 0; i < themes.length; i++)
    {
        var th=themes[i];
        var b = '<input type="submit" onclick="ThemeSwitcher.switch_theme(' + "'" + th + "'" + ');return false;" name="theme" value="' + th + ' theme"/>';
        buttons.push(b);
    }
    var inputs = buttons.join("\n");
    $("#theme_switch").append("<div id='toggle_theme_form' class='button'>Select Theme</div><form id='theme_form'>\n" + inputs + "\n</form>\n");
    if (!show_form)
    {
        // initially hide the form
        $( "#theme_form" ).toggle(false);
    }

    // add the onclick
    $( "#toggle_theme_form" ).click(function() {
        $( "#theme_form" ).toggle( "swing", function() {
            // Animation complete.
        });
    });
}


ThemeSwitcher.lookup_themes = function ( url, show_form )
{
    debug("ThemeSwitcher.lookup_thmes called with " + url);
    jQuery.getJSON(url)
        .done(function(data) {
            ThemeSwitcher.themes = data.themes;
            ThemeSwitcher.build_style_links(data.themes);
            ThemeSwitcher.build_form(data.themes, show_form);
            ThemeSwitcher.set_style_from_cookie();
        })
    .fail(function( jqxhr, textStatus, error ) {
        var err = textStatus + ", " + error;
        console.log( "Request Failed: " + err );
    });
}

ThemeSwitcher.switch_theme = function ( css_title )
{
    debug("ThemeSwitcher.switch_theme called");
  var i, link_tag ;
  for (i = 0, link_tag = document.getElementsByTagName("link") ; i < link_tag.length ; i++ ) {
    if ((link_tag[i].rel.indexOf( "stylesheet" ) != -1) &&
      link_tag[i].title) {
      link_tag[i].disabled = true ;
      if (link_tag[i].title == css_title) {
        link_tag[i].disabled = false ;
      }
    }
    docCookies.setItem( style_cookie_name, css_title, style_cookie_age, style_cookie_path );
  }
}

ThemeSwitcher.set_style_from_cookie = function ()
{
  var css_title = docCookies.getItem( style_cookie_name );
  if (css_title.length) {
    this.switch_theme( css_title );
  }
}


