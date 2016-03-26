package Mojolicious::Plugin::Foil;

=head1 NAME

Mojolicious::Plugin::Foil - looks for app

=head1 VERSION

This describes version 0.1

=cut

our $VERSION = '0.1';

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
    my $foilshared;

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

        return $self->_make_logo($c,%args);
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
    $app->routes->get('/foil/set' => sub {
            my $c        = shift;

            $self->_set_theme($c);
        })->name('foilset');
    $self->{main_route} = 'foilset';

    if (exists $conf->{add_prefixes}
            and defined $conf->{add_prefixes})
    {
        my @prefixes = @{$conf->{add_prefixes}};
        foreach my $rp (@prefixes)
        {
            $rp =~ s!/$!!; # remove trailing slash
            my $rname = $rp;
            $rname =~ s/[^a-zA-Z0-9]//g;
            $app->routes->get("${rp}/foil/set" => sub {
                    my $c        = shift;

                    $self->_set_theme($c);
                })->name("${rname}foilset");

            $self->{extra_routes}->{$rname} = $rp;
        }
    }
}

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
        die "failed to read themes from $theme_file";
    }
    if (ref $self->{themes} ne 'HASH')
    {
        die "themes not HASH $theme_file";
    }
    if (!exists $self->{themes}->{themes})
    {
        die "themes->themes not there $theme_file";
    }
    if (ref $self->{themes}->{themes} ne 'ARRAY')
    {
        die "themes->themes not ARRAY $theme_file";
    }
} # _get_themes

=head2 _make_theme_selector

For selecting themes.

=cut

sub _make_theme_selector {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $curr_theme = $self->_get_theme_id($c,%args);

    my $curr_url = $c->url_for('current');
    my $opt_url = $c->url_for($self->{main_route});
    # check if this matches one of the extra routes instead
    # Note that we remember the prefix when we make the extra route
    if (exists $self->{extra_routes}
            and defined $self->{extra_routes})
    {
        my @route_names = keys %{$self->{extra_routes}};
        foreach my $rname (@route_names)
        {
            my $prefix = $self->{extra_routes}->{$rname};
            my $rurl = $c->url_for($prefix);

            if ($curr_url =~ /^\Q$prefix\E\//)
            {
                $opt_url = $c->url_for("${prefix}/foil/set");
                last;
            }
        }
    }

    my @out = ();
    push @out, "<div class='themes'>";
    push @out, "<form action='$opt_url'>";
    push @out, '<input type="submit" value="Select theme"/>';
    push @out, '<select name="theme">';
    my @themes = @{$self->{themes}->{themes}};
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
    if (exists $c->config->{vhosts}->{$rhost}->{navbar_host})
    {
        $nb_host = $c->config->{vhosts}->{$rhost}->{navbar_host};
    }
    my @out = ();
    push @out, '<nav>';
    push @out, '<ul>';
    # we start always with Home
    push @out, "<li><a href='http://$nb_host/'>Home</a></li>";
    if (exists $c->config->{vhosts}->{$rhost}->{navbar_links})
    {
        foreach my $link (@{$c->config->{vhosts}->{$rhost}->{navbar_links}})
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
    if (exists $c->config->{vhosts}->{$rhost})
    {
        $hostname = $c->config->{vhosts}->{$rhost}->{name};
    }

    my $breadcrumb = "<b>$hostname</b> <a href='/'>Home</a>";
    if (defined $url)
    {
        $breadcrumb .= " &gt; <a href='$url'>$url</a>";
    }
    return $breadcrumb;
} # _make_breadcrumb

=head2 _make_logo

Make breadcrumb showing the previous page.

=cut

sub _make_logo {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $rhost = $c->req->headers->host;
    my $logoid = 'logo';
    if (exists $c->config->{vhosts}->{$rhost})
    {
        $logoid = $c->config->{vhosts}->{$rhost}->{logoid};
    }
    my $logo =<<"EOT";
<div id="$logoid" class="logo"><a href="/">Home</a></div>
EOT
    return $logo;
} # _make_logo

=head2 _get_theme_id

Get the ID of the current theme.

=cut

sub _get_theme_id {
    my $self = shift;
    my $c = shift;
    my %args = @_;

    my $theme = $c->session('theme');
    $theme = 'silver' if !$theme;
    return $theme;
} # _get_theme_id

=head2 _set_theme

For remembering themes.

=cut

sub _set_theme {
    my $self = shift;
    my $c = shift;

    my $theme = $c->param('theme');
    if ($theme)
    {
        $c->session->{theme} = $theme;
    }
    $c->redirect_to($c->req->headers->referrer);
} # _set_theme

1; # End of Mojolicious::Plugin::Foil

__DATA__

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
