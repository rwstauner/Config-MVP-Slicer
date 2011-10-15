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

# TODO: what's the moose way of accepting a callback? has match => isa => 'CodeRef'; $self->match->(@args); ?

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

The default separates plugin name from attribute name with a dot.

=cut

has separator => (
  is       => 'ro',
  isa      => 'Str',
  # "Module::Name.attribute" "-Plugin.variable"
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

Passing a plugin instance of C<'APlug'> would return:

  {
    'attr1'   => 'value1',
    'second'  => '2nd'
  }

=cut

sub slice {
  my ($self, $plugin) = @_;
  my ($name, $class, $prev) = $self->plugin_info($plugin);

# TODO: do we need to do anything to handle mvp_aliases?
# TODO: can/should we check $class->mvp_multivalue_args rather than if ref $value eq 'ARRAY'

  my $slice = {};
  my $config = $self->config;
  my $regexp = $self->separator_regexp;

  # sort to keep the bracket subscripts in order
  foreach my $key ( sort keys %$config ){
    next unless
      my ($plug, $attr, $array) = ($key =~ $regexp);
    my $value = $config->{ $key };

    # TODO: $self->match_name($plug, $name) || $self->match_package($plug, $class)
    next unless $plug eq $name || $plug eq $class;

    # TODO: should we allow for clearing previous []? $slice->{$attr} = [] if $overwrite;

    # TODO: $array || ref($prev->{$attr}) eq 'ARRAY'
    $self->_update_hash($slice, $attr, $value, {array => $array});
  }
  return $slice;
}

=method merge

  $slicer->merge($plugin, \%opts);

Get the config slice (see L</slice>),
then attempt to merge it into the plugin.

This require the plugin's attributes to be writable (C<'rw'>).

It will attempt to push onto array references and
concatenate onto existing strings (joined by a space).
It will overwrite any other types.

Possible options:

=for :list
* C<slice> - A hashref like that returned from L</slice>.  If not present, L</slice> will be called.

=cut

#* C<join> - A string that will be used to join a new value to any existing value instead of overwriting.

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
        Carp::croak("Attribute '$key' not found on $name\n");
        next;
      }
      my $type = $attr->type_constraint;
      my $previous = $plugin->$key;
      if( $previous ){
        # FIXME: do we need to check blessed() and/or isa()?
        if( ref $previous eq 'ARRAY' ){
          push(@$previous, $value);
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
}


=method plugin_info

  $slicer->plugin_info($plugin);

Used by other methods to normalize the information about a plugin.
Returns a list of C<< ($name, $package, \%config) >>.

If C<$plugin> is an arrayref it will simply dereference it.

If C<$plugin> is an instance of a plugin that has a C<plugin_name>
method it will contstruct the list from that method, C<ref>,
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
my ($parent);

=head1 SYNOPSIS

  my $slicer = Config::MVP::Slicer->new({
    config => $parent->config,
  });

  my $plugin_config = $slicer->slice($plugin);

=head1 DESCRIPTION

This can be used to separate embedded configurations for other plugins
out of larger (parent) configurations.

A prime example of this would be
L<Dist::Zilla  PluginBundles|Dist::Zilla::Role::PluginBundle>.

A bundle loads other plugins with a default configuration
that works most of the time, but sometimes you wish you could
customize the configuration for one of those plugins
without having the remove the plugin from the bundle
and re-specifiy it separately.

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
