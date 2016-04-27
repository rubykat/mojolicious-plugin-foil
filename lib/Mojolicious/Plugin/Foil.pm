package Mojolicious::Plugin::Foil;

# ABSTRACT: Mojolicious Plugin for CSS theming
=head1 NAME

Mojolicious::Plugin::Foil - looks for app

=head1 SYNOPSIS

    use Mojolicious::Plugin::Foil;

=head1 DESCRIPTION

Pretty themes; putting them in the application
instead of in javascript; it's faster this way.
Also other looks like breadcrumbs and other header stuff.

=cut

use Mojo::Base 'Mojolicious::Plugin';
use common::sense;
use File::Serialize;
use Path::Tiny;
use File::ShareDir 'module_dir';
use File::Slurper 'read_binary';
use Image::Size;

=head1 REGISTER

=cut

sub register {
    my ( $self, $app, $conf ) = @_;

    # Append class
    push @{$app->renderer->classes}, __PACKAGE__;
    push @{$app->static->classes},   __PACKAGE__;

    # Append directories
    # Find the Foil shared directory
    # It could be relative to the app home,
    # it could be relative to this current file,
    # it could be in a FileShared location.
    my $app_home = path($app->home);
    my $foilshared = $app_home->child("foil");

    if (!-d $foilshared)
    {
        my $mydir = path(__FILE__)->parent; # lib/Mojolicious/Plugin
        my $top = $mydir->parent->parent->parent;
        $foilshared = $top->child("foil");
        if (!-d $foilshared)
        {
            my $module_dir = path(module_dir(__PACKAGE__));
            $foilshared = $module_dir->child("foil");
        }
    }

    push @{$app->static->paths}, $foilshared;
    $self->{foilshared} = $foilshared;

    $self->_get_themes($app);

    $app->helper( 'foil_navbar' => sub {
        my $c        = shift;
        my %args     = @_;

        return $self->_make_navbar($c,%args);
    } );
    $app->helper( 'foil_breadcrumb' => sub {
        my $c        = shift;
        my %args     = @_;

        return $self->_make_breadcrumb($c,%args);
    } );
    $app->helper( 'foil_logo' => sub {
        my $c        = shift;
        my %args     = @_;

        return $self->_make_logo_css($c,%args);
    } );
    $app->helper( 'foil_theme_id' => sub {
        my $c        = shift;
        my %args     = @_;

        return $self->_get_theme_id($c,%args);
    } );
    $app->helper( 'foil_theme_selector' => sub {
        my $c        = shift;
        my %args     = @_;

        return $self->_make_theme_selector($c,%args);
    } );
    # add routes for setting the theme
    # and for delivering the logo
    $self->{set_route} = '/foil/set';
    $self->{logo_route} = '/foil/logo/:logo';
    $app->routes->get($self->{set_route} => sub {
            my $c        = shift;

            $self->_set_theme($c);
        });

    if (exists $conf->{add_prefixes}
            and defined $conf->{add_prefixes})
    {
        my @prefixes = @{$conf->{add_prefixes}};
        $self->{prefixes} = [];
        foreach my $rp (@prefixes)
        {
            $rp =~ s!/$!!; # remove trailing slash, if any
            push @{$self->{prefixes}}, $rp;
            $app->routes->get(${rp} . $self->{set_route} => sub {
                    my $c        = shift;

                    $self->_set_theme($c);
                });
        }
    } # prefixes
} # register

=head1 Helper Functions

These are functions which are NOT exported by this plugin.

=cut

=head2 _get_themes

Get the list of themes from the themes.json file.

=cut

sub _get_themes {
    my $self = shift;
    my $app = shift;

    my $theme_file = $self->{foilshared}->child("styles/themes/themes.json");
    if (!-f $theme_file)
    {
        die "'$theme_file' not found";
    }
    $self->{themes} = deserialize_file $theme_file;
    if (!defined $self->{themes})
    {
        die "'$theme_file' not parsed";
    }
    if (!defined $self->{themes}->{themes})
    {
        die "'$theme_file' not themes->themes";
    }
    if (ref $self->{themes}->{themes} ne 'HASH')
    {
        die "'$theme_file' themes->themes not HASH " . ref $self->{themes}->{themes};
    }
} # _get_themes

=head2 _get_prefix

Get the "prefix" part of the current route, if it has one

=cut

sub _get_prefix {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $route_prefix = '';
    my $curr_url = $c->url_for('current');
    # check if this matches one of the extra routes instead
    # Note that we remember the prefix when we make the extra route
    if (exists $self->{prefixes}
            and defined $self->{prefixes})
    {
        foreach my $prefix (@{$self->{prefixes}})
        {
            if ($curr_url =~ /^\Q$prefix\E\//)
            {
                $route_prefix = $prefix;
                last;
            }
        }
    }

    return $route_prefix;
} # _get_prefix

=head2 _make_theme_selector

For selecting themes.

=cut

sub _make_theme_selector {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $curr_theme = $self->_get_theme_id($c,%args);

    my $curr_url = $c->url_for('current');
    my $opt_url = $c->url_for($self->{set_route});
    my $prefix = $self->_get_prefix($c);
    if ($prefix)
    {
        $opt_url = $c->url_for(${prefix} . $self->{set_route});
    }

    my @out = ();
    push @out, "<div class='themes'>";
    push @out, "<form action='$opt_url'>";
    push @out, '<input type="submit" value="Select theme"/>';
    push @out, '<select name="theme">';
    my @themes = sort keys %{$self->{themes}->{themes}};
    for (my $i=0; $i < @themes; $i++)
    {
        my $th = $themes[$i];
        if ($th eq $curr_theme)
        {
            push @out, "<option value='$th' selected>$th</option>";
        }
        else
        {
            push @out, "<option value='$th'>$th</option>";
        }
    }
    push @out, '</select>';
    push @out, '</form>';
    push @out, '</div>';

    my $out = join("\n", @out);
    return $out;
} # _make_theme_selector

=head2 _make_navbar

Top-level navigation.
The difficulty with this is that using a reverse-proxy means that
all relative-ish URLs will be rewritten to be relative to this app.
So we need to take account of the host the request is coming from.
Absolute full URLs shouldn't be re-written.

=cut

sub _make_navbar {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $rhost = $c->req->headers->host;
    my $nb_host = $rhost;
    if (exists $c->config->{foil}->{$rhost}->{navbar_host})
    {
        $nb_host = $c->config->{foil}->{$rhost}->{navbar_host};
    }
    my @out = ();
    push @out, '<nav>';
    push @out, '<ul>';
    # we start always with Home
    push @out, "<li><a href='http://$nb_host/'>Home</a></li>";
    if (exists $c->config->{foil}->{$rhost}->{navbar_links})
    {
        foreach my $link (@{$c->config->{foil}->{$rhost}->{navbar_links}})
        {
            my $name = $link;
            if ($link =~ m{(\w+)/?$})
            {
                $name = ucfirst(lc($1));
            }
            if ($link =~ /^http/)
            {
                push @out, "<li><a href='${link}'>$name</a></li>";
            }
            else
            {
                push @out, "<li><a href='http://${nb_host}${link}'>$name</a></li>";
            }
        }
    }
    push @out, '</ul>';
    push @out, '</nav>';

    my $out = join("\n", @out);
    return $out;
} # _make_navbar

=head2 _make_breadcrumb

Make breadcrumb showing the previous page.

=cut

sub _make_breadcrumb {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $url = $c->req->headers->referrer;
    my $rhost = $c->req->headers->host;

    my $hostname = $rhost;
    if (exists $c->config->{foil}->{$rhost})
    {
        $hostname = $c->config->{foil}->{$rhost}->{name};
    }

    my $breadcrumb = "<b>$hostname</b> <a href='/'>Home</a>";
    if (defined $url)
    {
        $breadcrumb .= " &gt; <a href='$url'>$url</a>";
    }
    return $breadcrumb;
} # _make_breadcrumb

=head2 _make_logo_css

Make logo-link which points to the Home page.

=cut

sub _make_logo_css {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $curr_theme = $self->_get_theme_id($c,%args);
    my $logo_type = $self->{themes}->{themes}->{$curr_theme};
##    my $logo_prefix = '';

    my $logo_url = $c->url_for("/styles/themes/foil_${logo_type}.png");
    my $rhost = $c->req->headers->host;
    if (exists $c->config->{foil}->{$rhost}
            and $c->config->{foil}->{$rhost}->{"${logo_type}_url"})
    {
        $logo_url = $c->config->{foil}->{$rhost}->{"${logo_type}_url"};
    }
    my $logo_css =<<"EOT";
<div class="logo"><a href="/"><img src="$logo_url" alt="Home"/></a></div>
EOT
    return $logo_css;
} # _make_logo_css

=head2 _get_theme_id

Get the ID of the current theme.

=cut

sub _get_theme_id {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $rhost = $c->req->headers->host;
    my $theme = $c->session("theme_${rhost}");
    if (!$theme) # try default theme
    {
        my $rhost = $c->req->headers->host;
        if (exists $c->config->{foil}->{$rhost}
                and $c->config->{foil}->{$rhost}->{default_theme})
        {
            $theme = $c->config->{foil}->{$rhost}->{default_theme};
        }
    }
    $theme = 'silver' if !$theme; # fall back on silver
    return $theme;
} # _get_theme_id

=head2 _set_theme

For remembering themes.

=cut

sub _set_theme {
    my $self = shift;
    my $c = shift;

    my $rhost = $c->req->headers->host;
    my $theme = $c->param('theme');
    if ($theme)
    {
        $c->session->{"theme_${rhost}"} = $theme;
    }
    my $referrer = $c->req->headers->referrer;

    my $out =<<"EOT";
<p>Current theme is "$theme".</p>
<p>Back to: <a href='$referrer'>$referrer</a></p>
EOT
    $c->render(template=>'foil/settings',
        foil_settings=>$out);
} # _set_theme

1; # End of Mojolicious::Plugin::Foil

__DATA__

@@ foil/settings.html.ep
% layout 'foil';
<h1>Theme</h1>
<div>
<%== $foil_settings %>
</div>

@@ foil/header.html.ep
<div id="header_top">
<%== foil_logo %>
<%== foil_navbar %>
</div> <!-- /header_top -->
<div class="breadcrumb"><%== foil_breadcrumb %></div>

@@ foil/common_css.html.ep
<link rel="stylesheet" href="<%= url_for('/styles') %>/layout/layout_flex.css" type="text/css" />
<link rel="stylesheet" type="text/css" title="default" href="<%= url_for('/styles') %>/themes/theme_<%= foil_theme_id %>.css"/>

@@ layouts/foil.html.ep
<!DOCTYPE html>
<html>
<head>
    <title><%= title %></title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    %= include 'foil/common_css'
    %= content 'head_extra'
</head>
<body>
<div id="page-wrap">
    <header>
    %= include 'foil/header'
    </header>
  
    <div id="inner">
        <div id="main-wrap">
            <main>
                <%== content %>
            </main>
        </div> <!-- /main-wrap -->
        <div class="verso-wrap">
            <div class="side">
                %= content 'verso'
            </div> <!-- /side -->
        </div> <!-- /verso-wrap -->

        <div class="recto-wrap">
            <div class="side">
                %= content 'recto'
            </div> <!-- /side -->
        </div> <!-- /recto-wrap -->

    </div> <!-- /inner -->
    <div id="footer-wrap">
        <footer>
        %= content 'footer'
        </footer>
    </div> <!-- /footer-wrap -->
</div> <!-- /page-wrap -->
</body>
</html>
