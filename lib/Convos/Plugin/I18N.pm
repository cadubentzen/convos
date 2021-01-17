package Convos::Plugin::I18N;
use Mojo::Base 'Convos::Plugin';

use Convos::Util qw(DEBUG);
use HTTP::AcceptLanguage;
use Mojo::File qw(path);
use Mojo::Util qw(decode);

use constant RELOAD => $ENV{CONVOS_RELOAD_DICTIONARIES} || $ENV{MOJO_WEBPACK_LAZY} || 0;

has _dictionaries => sub { +{} };

sub register {
  my ($self, $app, $config) = @_;

  $app->helper('i18n.dictionary'        => sub { $self->_dictionary(@_) });
  $app->helper('i18n.languages'         => sub { [sort keys %{$self->_dictionaries}] });
  $app->helper('i18n.load_dictionaries' => sub { $self->_load_dictionaries(shift, @_) });
  $app->helper('l'                      => \&_l);
  $app->hook(around_action => sub { $self->_around_action(@_) });

  $app->i18n->load_dictionaries;
}

sub _around_action {
  my ($self, $next, $c, $action, $last) = @_;
  return $next->() unless $last;

  my $dictionaries = $self->_dictionaries;
  my $lang         = $c->param('lang') || $c->req->headers->accept_language || 'en';
  my $dict;
  for my $l (HTTP::AcceptLanguage->new($lang)->languages) {
    my ($prefix) = split /-/, $l;
    $dict = $dictionaries->{$l} || $dictionaries->{$prefix} and last;
  }

  $dict ||= $dictionaries->{en};
  $c->i18n->load_dictionaries($dict->{_l})                          if RELOAD;
  warn qq([Convos::Plugin::I18N] Using dictionary "$dict->{_l}".\n) if DEBUG >= 2;
  $c->stash(dictionary => $dict, lang => $dict->{_l});
  $next->();
}

sub _dictionary {
  my ($self, $c, $lang) = @_;
  return $self->_dictionaries->{$lang} ||= {_l => $lang, _n => 1};
}

sub _load_dictionaries {
  my ($self, $c, $load_lang) = @_;
  my $dictionaries = $self->_dictionaries;

  for my $file (map { path($_, 'i18n')->list->each } $c->app->asset->assets_dir) {
    next unless $file =~ m!([\w-]+)\.po$!;
    my $lang = $1;
    next if $load_lang and $load_lang ne $lang;
    _parse_po_file($file->realpath,
      sub { $dictionaries->{$lang}{$_[0]->{msgid}} = $_[0]->{msgstr} });
    my $l = $dictionaries->{$lang}{_l} = $lang;
    my $n = $dictionaries->{$lang}{_n} = int(keys %{$dictionaries->{$lang}}) - 1;
    warn qq([Convos::Plugin::I18N] Loaded $n lexicons for dictionary "$l" from $file.\n) if DEBUG;
  }
}

sub _parse_po_file {
  my $cb    = pop;
  my $PO    = shift->open;
  my $entry = {};
  while (<$PO>) {
    s![\r\n]!!g;
    $_                     = decode 'UTF-8', $_;
    @$entry{qw{file line}} = ($1, $2)      if /^#:\s*([^:]+):(\d+)/;
    $entry->{$1}           = _unescape($2) if /(msgid|msgstr)\s*(['"].*)/;
    next unless $entry->{msgid} and $entry->{msgstr};
    $cb->($entry);
    $entry = {};
  }
}

sub _l {
  my ($c, $lexicon, @args) = @_;
  $lexicon = $c->stash->{dictionary}{$lexicon} || $lexicon;
  $lexicon =~ s!%(\d+)!{$args[$1 - 1] // $1}!ge;
  return $lexicon;
}

sub _unescape {
  local $_ = $_[0];
  s!^['"]!! and s!['"]$!!;
  s!\\"!"!g;
  return $_;
}

1;

=encoding utf8

=head1 NAME

Convos::Plugin::I18N - Internationalization plugin for Convos

=head1 DESCRIPTION

L<Convos::Plugin::I18N> is a plugin for Convos to do translations.

=head1 HELPERS

=head2 i18n.dictionary

  $c->i18n->dictionary($lang);

Used to retrieve a dictionary for a given language.

=head2 i18n.languages

  $array_ref = $c->i18n->languages;

Used to retrieve a list of available languages.

=head2 l

  $str = $c->l($lexicon, @variables);

Will translate a C<$lexicon> and replace C<$1>, C<$2>, ... variables in the
string with C<@variables>.

=head2 i18n.load_dictionaries

  $c->i18n->load_dictionaries($lang);
  $c->i18n->load_dictionaries; # load all

Used to find available dictionaries (.po) files, parse them and build internal
structures.

=head1 METHODS

=head2 register

Used to register the L</HELPERS> and a "before_dispatch" hook which will detect
user language from the "Accept-Language" header.

=head1 SEE ALSO

L<Convos>.

=cut
