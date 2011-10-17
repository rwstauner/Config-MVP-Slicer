# vim: set ts=2 sts=2 sw=2 expandtab smarttab:
use strict;
use warnings;

package Config::MVP::Slicer;
# ABSTRACT: Separate embedded plugin config from parent config

use Carp (); # core
use Moose;

=attr config

This is the main/parent configuration hashref
that contains embedded plugin configurations.

=cut

has config => (
  is       => 'ro',
  isa      => 'HashRef',
);

=attr match_name

This is coderef that determines if a configuration line
matches a plugin's name.

It can be customized by passing an alternate subroutine reference
to the constructor.

The sub will receive two arguments:

=for :list
* The plugin name portion of the configuration line
* The name of the plugin being worked on (provided to L</slice>, for instance).

The default returns true if the current plugin name matches
the name from the config line
regardless of any leading "@Bundle/" prefixes in the plugin name
(as this is a common convention for bundles).

Obviously if the "@Bundle/" prefix is specified in the configuration
then it is required to be there for the default sub to match
(but multiple other "@Bundle/" prefixes will be allowed before it).

  # configuration line: "Foo.attr = value"

  $slicer->match_name("Foo", "Foo");            # true
  $slicer->match_name("Foo", "@Bar/Foo");       # true
  $slicer->match_name("Foo", "Bar");            # false

  # configuration line: "@B/Foo.attr = value"

  $slicer->match_name("@Bar/Foo", "Foo");           # false
  $slicer->match_name("@Bar/Foo", "@Bar/Foo");      # true
  $slicer->match_name("@Bar/Foo", "@Baz/@Bar/Foo"); # true
  $slicer->match_name("@Bar/Foo", "@Baz/Foo");      # false

=cut

has match_name => (
  is       => 'bare',
  isa      => 'CodeRef',
  traits   => ['Code'],
  default  => sub {
    # "@Bundle/Plugin" =~ "(@Bundle/)*Plugin"
    sub { scalar $_[1] =~ m{^(@.+?/)*?\Q$_[0]\E$} }
  },
  handles => {
    match_name => 'execute',
  },
);

=attr match_package

This works like L</match_name>
except that the configuration line is compared
to the plugin's package (class).

The default returns true if the two values are equal and false otherwise.

If you want to match by package rather than name
and you expand packages with (for example) a string prefix
you may need to set this to something like:

  match_package => sub { rewrite_prefix($_[0]) eq $_[1] }

=cut

has match_package => (
  is       => 'bare',
  isa      => 'CodeRef',
  traits   => ['Code'],
  default  => sub {
    sub { $_[0] eq $_[1] }
  },
  handles => {
    match_package => 'execute',
  },
);

=attr prefix

Regular expression that should match at the beginning of a key
before the module name and attribute:

  # prefix => 'dynamic\.'
  # { 'dynamic.Module::Name.attr' => 'value' }

Default is no prefix (empty string C<''>).

=cut

has prefix => (
  is       => 'ro',
  isa      => 'Str',
  default  => '',
);

=attr separator

A regular expression that will capture
the package name in C<$1> and
the attribute name in C<$2>.

The default separates plugin name from attribute name with a dot:

  'Module::Name.attribute'
  '-Plugin.attr'

=cut

has separator => (
  is       => 'ro',
  isa      => 'Str',
  default  => '(.+?)\.(.+?)',
);

=method separator_regexp

Returns a compiled regular expression (C<qr//>)
combining L</prefix>, L</separator>,
and the possible trailing array specification (C<\[.*?\]>).

=cut

sub separator_regexp {
  my ($self) = @_;
  return qr/^${\ $self->prefix }${\ $self->separator }(\[.*?\])?$/;
}

=method slice

  $slicer->slice($plugin);

Return a hashref of the config arguments for the plugin
determined by C<$plugin>.

This is a slice of the L</config> attribute
appropriate for the plugin passed to the method.

Starting with a config hashref of:

  {
    'APlug:attr1'   => 'value1',
    'APlug:second'  => '2nd',
    'OtherPlug:attr => '0'
  }

Passing a plugin instance of C<'APlug'>
(or an arrayref of C<< ['APlug', 'Full::Package::APlug', {}] >>)
would return:

  {
    'attr1'   => 'value1',
    'second'  => '2nd'
  }

=cut

sub slice {
  my ($self, $plugin) = @_;
  # ignore previous config
  my ($name, $pack) = $self->plugin_info($plugin);

# TODO: do we need to do anything to handle mvp_aliases?
# TODO: can/should we check $pack->mvp_multivalue_args rather than if ref $value eq 'ARRAY'

  my $slice = {};
  my $config = $self->config;
  my $regexp = $self->separator_regexp;

  # sort to keep the bracket subscripts in order
  foreach my $key ( sort keys %$config ){
    next unless
      my ($plug, $attr, $array) = ($key =~ $regexp);
    my $value = $config->{ $key };

    next unless
      $self->match_name($plug, $name) ||
      $self->match_package($plug, $pack);

    # TODO: should we allow for clearing previous []? $slice->{$attr} = [] if $overwrite;

    # TODO: $array || ref($prev->{$attr}) eq 'ARRAY'; # or is this handled by merge?
    $self->_update_hash($slice, $attr, $value, {array => $array});
  }
  return $slice;
}

=method merge

  $slicer->merge($plugin, \%opts);

Get the config slice (see L</slice>),
then attempt to merge it into the plugin.

If C<$plugin> is an arrayref the hashref will be modified.
If it is an object it's attributes should be writable (C<'rw'>).

This will append to array references
if it was specified as an array
or if a preexisting value is an arrayref.

Returns the modified C<$plugin> for convenience.

Possible options:

=for :list
* C<slice> - A hashref like that returned from L</slice>.  If not present, L</slice> will be called.

=cut

#* C<join> - A string that will be used to join a new value to any existing value instead of overwriting.
# TODO: allow option for reaching into blessed hashref?

sub merge {
  my ($self, $plugin, $opts) = @_;
  $opts ||= {};

  my $slice = $opts->{slice} || $self->slice($plugin);
  my ($name, $class, $conf) = $self->plugin_info($plugin);

  while( my ($key, $value) = each %$slice ){
    # merge into hashref
    if( ref($conf) eq 'HASH' ){
      $self->_update_hash($conf, $key, $value);
    }
    # plugin instance... attempt to update
    else {
      # call attribute writer (attribute must be 'rw'!)
      my $attr = $plugin->meta->find_attribute_by_name($key);
      if( !$attr ){
        # TODO: should we be dying here?
        Carp::croak("Attribute '$key' not found on $name/$class\n");
        next;
      }
      my $type = $attr->type_constraint;
      my $previous = $plugin->$key;
      if( $previous ){
        # FIXME: do we need to check blessed() and/or isa()?
        if( ref $previous eq 'ARRAY' ){
          push(@$previous, ref $value eq 'ARRAY' ? @$value : $value);
        }
        # if new value was specified as arrayref, attempt to merge
        elsif( ref $value eq 'ARRAY' ){
          $plugin->$key( [ $previous, @$value ] );
        }
        # is this useful?
        elsif( $type->name eq 'Str' && $opts->{join} ){
          $plugin->$key( join($opts->{join}, $previous, $value) );
        }
        # TODO: any other types?
        else {
          $plugin->$key($value);
        }
      }
      else {
        $value = [ $value ]
          if $type->name =~ /^arrayref/i && ref $value ne 'ARRAY';

        $plugin->$key($value);
      }
    }
  }
  return $plugin;
}


=method plugin_info

  $slicer->plugin_info($plugin);

Used by other methods to normalize the information about a plugin.
Returns a list of C<< ($name, $package, \%config) >>.

If C<$plugin> is an arrayref it will simply dereference it.
This can be useful for processing the results of plugin bundles.

If C<$plugin> is an instance of a plugin that has a C<plugin_name>
method it will construct the list from that method, C<ref>,
and the instance itself.

=cut

sub plugin_info {
  my ($self, $spec) = @_;

  # TODO: what should we do when name = "@Bundle/Plugin"? What adds that prefix?

  # Dist::Zilla::Role::PluginBundle: ['name', 'class', {con => 'fig'}]
  # TODO: accept a coderef for expanding the package name
  return @$spec
    if ref $spec eq 'ARRAY';

  # Dist::Zilla::Role::Plugin
  # Pod::Weaver::Role::Plugin
  return ($spec->plugin_name, ref($spec), $spec)
    if eval { $spec->can('plugin_name') };

  Carp::croak(qq[Don't know how to handle $spec]);
}

sub _update_hash {
  my ($self, $hash, $key, $value, $options) = @_;

  # concatenate array if
  if(
    # we know it should be an array
    $options->{array} ||
    # it already is an array
    (exists($hash->{ $key }) && ref($hash->{ $key }) eq 'ARRAY') ||
    # the new value is an array
    ref($value) eq 'ARRAY'
  ){
    # if there is an initial value but it's not an array ref, convert it
    $hash->{ $key } = [ $hash->{ $key } ]
      if exists $hash->{ $key } && ref $hash->{ $key } ne 'ARRAY';

    push @{ $hash->{ $key } }, ref($value) eq 'ARRAY' ? @$value : $value;
  }
  # else overwrite
  else {
    $hash->{ $key } = $value;
  }
}

# TODO: learn which of these are supposed to be here:
__PACKAGE__->meta->make_immutable;
no Moose;
1;

=for test_synopsis
my ($parent, $plugin);

=head1 SYNOPSIS

  my $slicer = Config::MVP::Slicer->new({
    config => $parent->config,
  });

  # extract a hashref from the parent config without modifying the plugin
  my $plugin_config = $slicer->slice($plugin);

  # from plugin bundles:
  my $plugin_spec = ['Name', 'Package::Name', {default => 'config'}];
  # update the hashref
  $slicer->merge($plugin_spec);

  # with object instances:
  my $plugger = App::Plugin::Plugger->new({some => 'config'});
  # update 'rw' attributes
  $slicer->merge($plugger);

=head1 DESCRIPTION

This can be used to extract embedded configurations for other plugins
out of larger (parent) configurations.

A prime example of this would be
L<Dist::Zilla Plugin Bundles|Dist::Zilla::Role::PluginBundle>.

A bundle loads other plugins with a default configuration
that works most of the time, but sometimes you wish you could
customize the configuration for one of those plugins
without having to remove the plugin from the bundle
and re-specify it separately.

  # dist.ini
  [@MyBundle]
  Other::Plugin.heart = dist-zilla

Now you can accept customizations to plugins into your
config and separate them out using this.

Also see L<Dist::Zilla::Role::PluginBundle::EmebeddedConfig>
to enable this functionality automatically in your bundle
with one line.

=cut

# TODO: document Plugin.value[0], Plugin.value[1] to work around inability to declare
# all possible values in mvp_multivalue_args
# "since sorting numerically probably isn't going to do what you want"
